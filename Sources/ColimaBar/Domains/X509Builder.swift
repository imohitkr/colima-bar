import CryptoKit
import Foundation
import Security

/// Builds the X.509 certificates of the local certificate authority. Pure,
/// except `sign`. P-256 keys and ecdsa-with-SHA256 only.
enum X509Builder {
    struct Spec: Equatable, Sendable {
        /// 16 bytes, top bit cleared, not all zero.
        var serial: [UInt8]
        var subjectCN: String
        var organization: String?
        /// The DER of the issuer name. For the CA, the DER of its own name.
        var issuerName: [UInt8]
        var notBefore: Date
        var notAfter: Date
        /// 65 bytes: `04 || X || Y`.
        var publicKeyX963: [UInt8]
        /// The key ID of the issuer, for a leaf.
        var issuerKeyID: [UInt8]?
        var kind: Kind

        enum Kind: Equatable, Sendable {
            case ca(permittedDNS: [String])
            /// `ipAddresses` are 4 or 16 bytes each. Only a test uses them.
            case leaf(dnsNames: [String], ipAddresses: [[UInt8]] = [])
        }
    }

    // OIDs
    private static let ecdsaSHA256 = DER.seq(DER.oid("1.2.840.10045.4.3.2"))
    static let oidBasicConstraints = "2.5.29.19"
    private static let oidKeyUsage = "2.5.29.15"
    private static let oidNameConstraints = "2.5.29.30"
    private static let oidExtKeyUsage = "2.5.29.37"
    private static let oidSAN = "2.5.29.17"
    private static let oidAKI = "2.5.29.35"
    private static let oidSKI = "2.5.29.14"
    private static let serverAuth = "1.3.6.1.5.5.7.3.1"

    /// The DER of a Name with an optional organization and a common name.
    static func name(cn: String, organization: String?) -> [UInt8] {
        var rdns: [[UInt8]] = []
        if let organization { rdns.append(DER.set(DER.seq(DER.oid("2.5.4.10"), DER.utf8(organization)))) }
        rdns.append(DER.set(DER.seq(DER.oid("2.5.4.3"), DER.utf8(cn))))
        return DER.seqOf(rdns)
    }

    /// The key ID of a public key: the SHA-1 of its 65 bytes. It names a key,
    /// it protects nothing.
    static func keyID(_ x963: [UInt8]) -> [UInt8] { Array(Insecure.SHA1.hash(data: x963)) }

    static func spki(_ x963: [UInt8]) -> [UInt8] {
        DER.seq(DER.seq(DER.oid("1.2.840.10045.2.1"), DER.oid("1.2.840.10045.3.1.7")), DER.bits(x963))
    }

    private static func ext(_ oid: String, critical: Bool = false, _ value: [UInt8]) -> [UInt8] {
        critical ? DER.seq(DER.oid(oid), DER.bool(true), DER.octets(value)) : DER.seq(DER.oid(oid), DER.octets(value))
    }

    /// The NameConstraints value: the permitted DNS names, and the whole IPv4
    /// and IPv6 space excluded. So the CA signs no certificate for an address.
    static func nameConstraints(permittedDNS: [String]) -> [UInt8] {
        let permitted = permittedDNS.flatMap { DER.seq(DER.tlv(0x82, Array($0.utf8))) }
        let excluded =
            DER.seq(DER.tlv(0x87, [UInt8](repeating: 0, count: 8)))
            + DER.seq(DER.tlv(0x87, [UInt8](repeating: 0, count: 32)))
        return DER.seq(DER.ctx(0, permitted), DER.ctx(1, excluded))
    }

    /// The extensions, in a fixed order.
    static func extensions(_ spec: Spec) -> [[UInt8]] {
        var out: [[UInt8]] = []
        switch spec.kind {
        case .ca(let permitted):
            out.append(ext(oidBasicConstraints, critical: true, DER.seq(DER.bool(true), DER.int(0))))
            out.append(ext(oidKeyUsage, critical: true, DER.bits([0x06], unused: 1)))  // keyCertSign, cRLSign
            out.append(ext(oidNameConstraints, critical: true, nameConstraints(permittedDNS: permitted)))
            out.append(ext(oidExtKeyUsage, DER.seq(DER.oid(serverAuth))))
        case .leaf(let dnsNames, let ipAddresses):
            out.append(ext(oidBasicConstraints, critical: true, DER.seq()))
            out.append(ext(oidKeyUsage, critical: true, DER.bits([0x80], unused: 7)))  // digitalSignature
            out.append(ext(oidExtKeyUsage, DER.seq(DER.oid(serverAuth))))
            let names = dnsNames.map { DER.tlv(0x82, Array($0.utf8)) } + ipAddresses.map { DER.tlv(0x87, $0) }
            out.append(ext(oidSAN, DER.seqOf(names)))
            if let issuer = spec.issuerKeyID {
                out.append(ext(oidAKI, DER.seq(DER.ctx(0, constructed: false, issuer))))
            }
        }
        out.append(ext(oidSKI, DER.octets(keyID(spec.publicKeyX963))))
        return out
    }

    /// The part of the certificate that the issuer signs.
    static func tbs(_ spec: Spec) -> [UInt8] {
        DER.seq(
            DER.ctx(0, DER.int(2)), DER.int(spec.serial), ecdsaSHA256, spec.issuerName,
            DER.seq(DER.time(spec.notBefore), DER.time(spec.notAfter)),
            name(cn: spec.subjectCN, organization: spec.organization), spki(spec.publicKeyX963),
            DER.ctx(3, DER.seqOf(extensions(spec))))
    }

    static func certificate(tbs: [UInt8], signature: [UInt8]) -> [UInt8] {
        DER.seq(tbs, ecdsaSHA256, DER.bits(signature))
    }

    static func sign(_ tbs: [UInt8], with key: SecKey) throws -> [UInt8] {
        var error: Unmanaged<CFError>?
        guard
            let signature = SecKeyCreateSignature(key, .ecdsaSignatureMessageX962SHA256, Data(tbs) as CFData, &error)
                as Data?
        else { throw error?.takeRetainedValue() ?? POSIXError(.EIO) }
        return [UInt8](signature)
    }

    static func pem(_ der: [UInt8]) -> String {
        let body = Data(der).base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
        return "-----BEGIN CERTIFICATE-----\n\(body)\n-----END CERTIFICATE-----\n"
    }

    /// A random 16 byte serial with the top bit cleared. It is never all zero.
    static func randomSerial() -> [UInt8] {
        var serial = [UInt8](repeating: 0, count: 16)
        repeat {
            _ = SecRandomCopyBytes(kSecRandomDefault, serial.count, &serial)
            serial[0] &= 0x7F
        } while serial.allSatisfy { $0 == 0 }
        return serial
    }

    /// The permitted DNS names of the NameConstraints of a CA certificate, or
    /// nil if the DER has none or is malformed.
    static func permittedDNS(certificateDER der: [UInt8]) -> [String]? {
        guard let cert = DER.read(der[...]), cert.tag == 0x30,
            let top = DER.children(cert.content), let tbs = top.first, tbs.tag == 0x30,
            let fields = DER.children(tbs.content),
            let wrapper = fields.first(where: { $0.tag == 0xA3 }),
            let list = DER.read(wrapper.content), let extensions = DER.children(list.content)
        else { return nil }
        let nameConstraintsOID = Array(DER.oid(oidNameConstraints).dropFirst(2))
        for e in extensions {
            guard let parts = DER.children(e.content), let id = parts.first, Array(id.content) == nameConstraintsOID,
                let value = parts.last, value.tag == 0x04, let body = DER.read(value.content),
                let trees = DER.children(body.content), let permitted = trees.first(where: { $0.tag == 0xA0 }),
                let subtrees = DER.children(permitted.content)
            else { continue }
            return subtrees.compactMap { subtree in
                guard let general = DER.children(subtree.content)?.first, general.tag == 0x82 else { return nil }
                return String(decoding: general.content, as: UTF8.self)
            }
        }
        return nil
    }
}
