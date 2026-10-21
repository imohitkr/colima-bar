import CryptoKit
import Foundation
import Security

/// The local certificate authority of HTTPS for container domains. It is a
/// P-256 CA, constrained to the DNS names in `permitted` with every IP
/// address excluded (`X509Builder.nameConstraints`), for server
/// authentication only. The key lives in memory and in a 0600 file
/// (`LocalCAStore`). It is never a keychain item.
///
/// Immutable after creation. Security objects are thread safe, so the value
/// is `@unchecked Sendable`.
struct LocalCA: @unchecked Sendable {
    let certificate: SecCertificate
    let der: [UInt8]
    let key: SecKey
    /// `04 || X || Y` of the public key.
    let publicX963: [UInt8]
    /// The DER of the subject name, which is also the issuer name of each leaf.
    let name: [UInt8]
    let keyID: [UInt8]
    let permitted: [String]

    static let commonNamePrefix = "ColimaBar Local CA"
    static let organization = "ColimaBar"
    static let validityDays = 3650
    static let leafDays = 30
    /// A certificate starts this early, so a small clock error does not break it.
    static let backdate: TimeInterval = 3600

    enum Failure: Error, Equatable {
        case key
        case certificate
        case keyMismatch
    }

    /// The SHA-1 of the certificate, for logs. `security` lists the same value.
    var sha1: [UInt8] { Array(Insecure.SHA1.hash(data: der)) }

    var commonName: String { Self.commonName(keyID: keyID) }

    static func commonName(keyID: [UInt8]) -> String {
        "\(commonNamePrefix) \(keyID.prefix(4).map { String(format: "%02x", $0) }.joined())"
    }

    /// A new CA with a new key. It does no I/O.
    static func create(permitted: [String], now: Date = Date()) throws -> LocalCA {
        let key = try newKey()
        let x963 = try publicX963(of: key)
        let id = X509Builder.keyID(x963)
        let name = X509Builder.name(cn: commonName(keyID: id), organization: organization)
        let spec = X509Builder.Spec(
            serial: X509Builder.randomSerial(), subjectCN: commonName(keyID: id), organization: organization,
            issuerName: name, notBefore: now.addingTimeInterval(-backdate),
            notAfter: now.addingTimeInterval(Double(validityDays) * 86400), publicKeyX963: x963, issuerKeyID: nil,
            kind: .ca(permittedDNS: permitted))
        let tbs = X509Builder.tbs(spec)
        let der = X509Builder.certificate(tbs: tbs, signature: try X509Builder.sign(tbs, with: key))
        guard let certificate = SecCertificateCreateWithData(nil, Data(der) as CFData) else {
            throw Failure.certificate
        }
        return LocalCA(
            certificate: certificate, der: der, key: key, publicX963: x963, name: name, keyID: id,
            permitted: permitted)
    }

    /// The CA of saved files. The certificate must be a valid self-signed CA
    /// (issuer is subject, CA flag, inside its dates, signature of its own
    /// key), and the key must belong to it: a nonce that the key signs must
    /// verify with the public key of the certificate.
    static func restore(certificateDER der: [UInt8], keyX963: [UInt8], now: Date = Date()) throws -> LocalCA {
        guard let certificate = SecCertificateCreateWithData(nil, Data(der) as CFData),
            let certKey = SecCertificateCopyKey(certificate), let certX963 = try? publicX963(of: certKey),
            let info = X509Builder.readCA(certificateDER: der),
            info.isCA, info.issuer == info.subject, info.notBefore <= now, now <= info.notAfter,
            SecKeyVerifySignature(
                certKey, .ecdsaSignatureMessageX962SHA256, Data(info.tbs) as CFData, Data(info.signature) as CFData,
                nil)
        else { throw Failure.certificate }
        guard keyX963.count == 97 else { throw Failure.key }
        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom, kSecAttrKeyClass: kSecAttrKeyClassPrivate,
            kSecAttrKeySizeInBits: 256,
        ]
        guard let key = SecKeyCreateWithData(Data(keyX963) as CFData, attributes as CFDictionary, nil),
            let x963 = try? publicX963(of: key)
        else { throw Failure.key }
        guard x963 == certX963, signsFor(key, certKey) else { throw Failure.keyMismatch }
        guard let permitted = X509Builder.permittedDNS(certificateDER: der) else { throw Failure.certificate }
        return LocalCA(
            certificate: certificate, der: der, key: key, publicX963: x963, name: info.subject,
            keyID: X509Builder.keyID(x963), permitted: permitted)
    }

    /// True when `key` signs a new nonce and `publicKey` verifies it.
    private static func signsFor(_ key: SecKey, _ publicKey: SecKey) -> Bool {
        var nonce = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, nonce.count, &nonce) == errSecSuccess,
            let signature = SecKeyCreateSignature(key, .ecdsaSignatureMessageX962SHA256, Data(nonce) as CFData, nil)
        else { return false }
        return SecKeyVerifySignature(
            publicKey, .ecdsaSignatureMessageX962SHA256, Data(nonce) as CFData, signature, nil)
    }

    /// True when every name of `suffixes` is a permitted name of this CA.
    func covers(_ suffixes: [String]) -> Bool { Set(suffixes).isSubset(of: Set(permitted)) }

    /// The private key as `04 || X || Y || D`, for the key file.
    func keyX963() throws -> [UInt8] {
        var error: Unmanaged<CFError>?
        guard let data = SecKeyCopyExternalRepresentation(key, &error) as Data? else {
            throw error?.takeRetainedValue() ?? Failure.key
        }
        return [UInt8](data)
    }

    /// A leaf for `names`, valid for 30 days, signed by this CA. The key is
    /// new and not permanent.
    func mintLeaf(names: [String], now: Date = Date()) throws -> (
        certificate: SecCertificate, key: SecKey, notAfter: Date
    ) {
        let leafKey = try Self.newKey()
        let x963 = try Self.publicX963(of: leafKey)
        let notAfter = now.addingTimeInterval(Double(Self.leafDays) * 86400)
        // A common name has at most 64 characters. The names are in the SAN.
        let first = names.first ?? DomainName.localhost
        let spec = X509Builder.Spec(
            serial: X509Builder.randomSerial(), subjectCN: first.utf8.count <= 64 ? first : "ColimaBar",
            organization: nil,
            issuerName: name, notBefore: now.addingTimeInterval(-Self.backdate), notAfter: notAfter,
            publicKeyX963: x963, issuerKeyID: keyID, kind: .leaf(dnsNames: names))
        let tbs = X509Builder.tbs(spec)
        let der = X509Builder.certificate(tbs: tbs, signature: try X509Builder.sign(tbs, with: key))
        guard let leaf = SecCertificateCreateWithData(nil, Data(der) as CFData) else { throw Failure.certificate }
        return (leaf, leafKey, notAfter)
    }

    // MARK: - Keys

    /// A P-256 key that is never permanent: it never goes into a keychain.
    static func newKey() throws -> SecKey {
        var error: Unmanaged<CFError>?
        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom, kSecAttrKeySizeInBits: 256,
            kSecPrivateKeyAttrs: [kSecAttrIsPermanent: false],
        ]
        guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            throw error?.takeRetainedValue() ?? Failure.key
        }
        return key
    }

    /// `04 || X || Y` of the public key of `key`, a public or a private key.
    static func publicX963(of key: SecKey) throws -> [UInt8] {
        guard let pub = SecKeyCopyPublicKey(key) ?? (isPublic(key) ? key : nil) else { throw Failure.key }
        var error: Unmanaged<CFError>?
        guard let data = SecKeyCopyExternalRepresentation(pub, &error) as Data? else {
            throw error?.takeRetainedValue() ?? Failure.key
        }
        return [UInt8](data)
    }

    private static func isPublic(_ key: SecKey) -> Bool {
        let attributes = SecKeyCopyAttributes(key) as? [CFString: Any]
        return (attributes?[kSecAttrKeyClass] as? String) == (kSecAttrKeyClassPublic as String)
    }
}
