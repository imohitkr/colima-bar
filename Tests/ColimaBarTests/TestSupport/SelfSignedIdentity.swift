import CommonCrypto
import Foundation
import Security

/// A self-signed TLS server identity for a test, built in memory. No keychain
/// and no file: the key is not permanent, and `SecIdentityCreate` joins it to
/// the certificate. The certificate is for `localhost`. Nothing trusts it, so
/// a client must accept it by its own verify block, like the proxy does.
enum SelfSignedIdentity {
    @_silgen_name("SecIdentityCreate")
    private static func secIdentityCreate(_ a: CFAllocator?, _ cert: SecCertificate, _ key: SecKey) -> Unmanaged<
        SecIdentity
    >?

    static func make(commonName: String = "localhost") -> SecIdentity? {
        var error: Unmanaged<CFError>?
        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom, kSecAttrKeySizeInBits: 256,
            kSecPrivateKeyAttrs: [kSecAttrIsPermanent: false],
        ]
        guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &error),
            let der = try? certificate(key: key, commonName: commonName),
            let cert = SecCertificateCreateWithData(nil, Data(der) as CFData)
        else { return nil }
        return secIdentityCreate(nil, cert, key)?.takeRetainedValue()
    }

    // MARK: - DER

    private static func length(_ n: Int) -> [UInt8] {
        if n < 0x80 { return [UInt8(n)] }
        var v = n
        var out: [UInt8] = []
        while v > 0 {
            out.insert(UInt8(v & 0xff), at: 0)
            v >>= 8
        }
        return [0x80 | UInt8(out.count)] + out
    }

    private static func tlv(_ tag: UInt8, _ body: [UInt8]) -> [UInt8] { [tag] + length(body.count) + body }
    private static func seq(_ items: [UInt8]...) -> [UInt8] { tlv(0x30, items.flatMap { $0 }) }
    private static func integer(_ bytes: [UInt8]) -> [UInt8] {
        var b = Array(bytes.drop { $0 == 0 })
        if b.isEmpty { b = [0] }
        if b[0] & 0x80 != 0 { b.insert(0, at: 0) }
        return tlv(0x02, b)
    }

    private static func oid(_ s: String) -> [UInt8] {
        let parts = s.split(separator: ".").compactMap { Int($0) }
        var out: [UInt8] = [UInt8(parts[0] * 40 + parts[1])]
        for var v in parts.dropFirst(2) {
            var chunk: [UInt8] = [UInt8(v & 0x7f)]
            v >>= 7
            while v > 0 {
                chunk.insert(UInt8(v & 0x7f) | 0x80, at: 0)
                v >>= 7
            }
            out += chunk
        }
        return tlv(0x06, out)
    }

    private static func utcTime(_ date: Date) -> [UInt8] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyMMddHHmmss'Z'"
        return tlv(0x17, Array(formatter.string(from: date).utf8))
    }

    private static func certificate(key: SecKey, commonName: String) throws -> [UInt8] {
        guard let pub = SecKeyCopyPublicKey(key), let raw = SecKeyCopyExternalRepresentation(pub, nil) as Data? else {
            throw POSIXError(.EIO)
        }
        let algorithm = seq(oid("1.2.840.10045.4.3.2"))  // ecdsa-with-SHA256
        let name = seq(tlv(0x31, seq(oid("2.5.4.3"), tlv(0x0c, Array(commonName.utf8)))))
        var serial = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, 16, &serial)
        serial[0] &= 0x7f
        let now = Date()
        let spki = seq(
            seq(oid("1.2.840.10045.2.1"), oid("1.2.840.10045.3.1.7")), tlv(0x03, [0] + [UInt8](raw)))
        let san = seq(oid("2.5.29.17"), tlv(0x04, seq(tlv(0x82, Array(commonName.utf8)))))
        let tbs = seq(
            tlv(0xa0, integer([2])), integer(serial), algorithm, name,
            seq(utcTime(now.addingTimeInterval(-3600)), utcTime(now.addingTimeInterval(86400))),
            name, spki, tlv(0xa3, seq(san)))
        var error: Unmanaged<CFError>?
        guard
            let signature = SecKeyCreateSignature(
                key, .ecdsaSignatureMessageX962SHA256, Data(tbs) as CFData, &error) as Data?
        else { throw POSIXError(.EIO) }
        return seq(tbs, algorithm, tlv(0x03, [0] + [UInt8](signature)))
    }
}
