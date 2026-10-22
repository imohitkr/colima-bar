import CommonCrypto
import Foundation
import Security

/// Makes a `SecIdentity` of a certificate and its private key without a
/// keychain. It builds a PKCS#12 file in memory and imports it with
/// `kSecImportToMemoryOnly`, so nothing is written anywhere.
enum PKCS12 {
    enum Failure: Error { case key, random, importFailed(OSStatus) }

    /// The identity of `certificate` and the P-256 key `key`. The key must
    /// be able to export itself, which a key of `LocalCA.newKey` can.
    static func identity(certificate: SecCertificate, key: SecKey) throws -> SecIdentity {
        let password = try randomPassword()
        let file = try file(certificate: certificate, key: key, password: password)
        return try importIdentity(Data(file), password: password)
    }

    /// Imports a PKCS#12 file into memory only and returns its identity.
    static func importIdentity(_ file: Data, password: String) throws -> SecIdentity {
        let options: [CFString: Any] = [kSecImportToMemoryOnly: true, kSecImportExportPassphrase: password]
        var items: CFArray?
        let status = SecPKCS12Import(file as CFData, options as CFDictionary, &items)
        guard status == errSecSuccess else { throw Failure.importFailed(status) }
        let first = (items as? [[String: Any]])?.first
        guard let value = first?[kSecImportItemIdentity as String],
            CFGetTypeID(value as CFTypeRef) == SecIdentityGetTypeID()
        else { throw Failure.importFailed(errSecItemNotFound) }
        return value as! SecIdentity
    }

    /// The bytes of the PKCS#12 file.
    static func file(certificate: SecCertificate, key: SecKey, password: String) throws -> [UInt8] {
        var error: Unmanaged<CFError>?
        guard let external = SecKeyCopyExternalRepresentation(key, &error) as Data? else {
            throw error?.takeRetainedValue() ?? Failure.key
        }
        // A P-256 private key is `04 || X || Y || K`.
        let x963 = [UInt8](external)
        guard x963.count == 97, x963[0] == 4 else { throw Failure.key }
        let publicPart = Array(x963[0..<65])
        let scalar = Array(x963[65..<97])
        let certificateDER = [UInt8](SecCertificateCopyData(certificate) as Data)
        return build(
            certificate: certificateDER, scalar: scalar, publicPoint: publicPart,
            keyID: X509Builder.keyID(publicPart), password: password)
    }

    static func build(
        certificate: [UInt8], scalar: [UInt8], publicPoint: [UInt8], keyID: [UInt8], password: String,
        salt: [UInt8] = []
    ) -> [UInt8] {
        let ecPrivateKey = DER.seq(DER.int(1), DER.octets(scalar), DER.ctx(1, DER.bits(publicPoint)))
        let pkcs8 = DER.seq(
            DER.int(0), DER.seq(DER.oid("1.2.840.10045.2.1"), DER.oid("1.2.840.10045.3.1.7")),
            DER.octets(ecPrivateKey))
        let localKeyID = DER.seq(DER.oid("1.2.840.113549.1.9.21"), DER.set(DER.octets(keyID)))
        let keyBag = DER.seq(
            DER.oid("1.2.840.113549.1.12.10.1.2"), DER.ctx(0, shroud(pkcs8, password: password)), DER.set(localKeyID))
        let certBag = DER.seq(
            DER.oid("1.2.840.113549.1.12.10.1.3"),
            DER.ctx(0, DER.seq(DER.oid("1.2.840.113549.1.9.22.1"), DER.ctx(0, DER.octets(certificate)))),
            DER.set(localKeyID))
        let safeContents = DER.seq(keyBag, certBag)
        let authenticatedSafe = DER.seq(DER.seq(DER.oid("1.2.840.113549.1.7.1"), DER.ctx(0, DER.octets(safeContents))))
        let macSalt = salt.isEmpty ? (try? randomBytes(16)) ?? [UInt8](repeating: 7, count: 16) : salt
        let iterations = 1
        let macKey = kdf(password: password, salt: macSalt, iterations: iterations, id: 3, length: 32)
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        macKey.withUnsafeBytes { k in
            authenticatedSafe.withUnsafeBytes { m in
                CCHmac(CCHmacAlgorithm(kCCHmacAlgSHA256), k.baseAddress, k.count, m.baseAddress, m.count, &digest)
            }
        }
        let macData = DER.seq(
            DER.seq(DER.seq(DER.oid("2.16.840.1.101.3.4.2.1"), DER.tlv(5, [])), DER.octets(digest)),
            DER.octets(macSalt), DER.int(iterations))
        return DER.seq(
            DER.int(3), DER.seq(DER.oid("1.2.840.113549.1.7.1"), DER.ctx(0, DER.octets(authenticatedSafe))), macData)
    }

    /// An EncryptedPrivateKeyInfo with PBES2: PBKDF2 with HMAC-SHA256 and AES-256-CBC.
    static func shroud(_ plain: [UInt8], password: String) -> [UInt8] {
        let salt = (try? randomBytes(16)) ?? [UInt8](repeating: 3, count: 16)
        let iv = (try? randomBytes(16)) ?? [UInt8](repeating: 5, count: 16)
        let iterations = 2048
        var aesKey = [UInt8](repeating: 0, count: 32)
        let pw = Array(password.utf8)
        pw.withUnsafeBufferPointer { p in
            p.withMemoryRebound(to: Int8.self) { pwc in
                _ = CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2), pwc.baseAddress, pwc.count, salt, salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), UInt32(iterations), &aesKey, aesKey.count)
            }
        }
        var encrypted = [UInt8](repeating: 0, count: plain.count + kCCBlockSizeAES128)
        var written = 0
        let status = CCCrypt(
            CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding), aesKey,
            aesKey.count, iv, plain, plain.count, &encrypted, encrypted.count, &written)
        precondition(status == kCCSuccess, "AES cannot fail with these sizes")
        encrypted = Array(encrypted.prefix(written))
        let kdfParams = DER.seq(
            DER.oid("1.2.840.113549.1.5.12"),
            DER.seq(
                DER.octets(salt), DER.int(iterations),
                DER.seq(DER.oid("1.2.840.113549.2.9"), DER.tlv(5, []))))
        let cipher = DER.seq(DER.oid("2.16.840.1.101.3.4.1.42"), DER.octets(iv))
        return DER.seq(
            DER.seq(DER.oid("1.2.840.113549.1.5.13"), DER.seq(kdfParams, cipher)), DER.octets(encrypted))
    }

    static func randomBytes(_ count: Int) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: count)
        guard SecRandomCopyBytes(kSecRandomDefault, count, &bytes) == errSecSuccess else { throw Failure.random }
        return bytes
    }

    static func randomPassword() throws -> String { Data(try randomBytes(24)).base64EncodedString() }

    /// The key derivation of RFC 7292 appendix B with SHA-256. `id` is 1 for
    /// a key, 2 for an IV and 3 for a MAC key.
    static func kdf(password: String, salt: [UInt8], iterations: Int, id: UInt8, length: Int) -> [UInt8] {
        let u = Int(CC_SHA256_DIGEST_LENGTH)
        let v = 64
        // The password is a BMPString with a terminating zero.
        var pw: [UInt8] = password.utf16.flatMap { [UInt8($0 >> 8), UInt8($0 & 0xFF)] }
        pw += [0, 0]
        func stretch(_ bytes: [UInt8]) -> [UInt8] {
            guard !bytes.isEmpty else { return [] }
            let count = v * ((bytes.count + v - 1) / v)
            return (0..<count).map { bytes[$0 % bytes.count] }
        }
        var input = stretch(salt) + stretch(pw)
        let diversifier = [UInt8](repeating: id, count: v)
        var out: [UInt8] = []
        while out.count < length {
            var a = diversifier + input
            for _ in 0..<iterations {
                var h = [UInt8](repeating: 0, count: u)
                CC_SHA256(a, CC_LONG(a.count), &h)
                a = h
            }
            out += a
            if out.count >= length { break }
            let b = stretch(a).prefix(v)
            // I_j = (I_j + B + 1) mod 2^v for each block of I.
            for block in stride(from: 0, to: input.count, by: v) {
                var carry = 1
                for i in stride(from: v - 1, through: 0, by: -1) {
                    let sum = Int(input[block + i]) + Int(b[b.startIndex + i]) + carry
                    input[block + i] = UInt8(sum & 0xFF)
                    carry = sum >> 8
                }
            }
        }
        return Array(out.prefix(length))
    }
}
