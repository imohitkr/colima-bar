import Foundation

/// What `LocalCA.restore` reads from a CA certificate to check it.
extension X509Builder {
    struct CAInfo {
        /// The DER of the part that the issuer signed.
        var tbs: [UInt8]
        /// The DER of the ECDSA signature.
        var signature: [UInt8]
        var issuer: [UInt8]
        var subject: [UInt8]
        var notBefore: Date
        var notAfter: Date
        /// True when basicConstraints says that this is a CA.
        var isCA: Bool
    }

    /// The fields of a certificate, or nil if the DER is malformed.
    static func readCA(certificateDER der: [UInt8]) -> CAInfo? {
        guard let cert = DER.read(der[...]), cert.tag == 0x30, let top = DER.children(cert.content), top.count == 3,
            top[0].tag == 0x30, top[2].tag == 0x03, top[2].content.count > 1, top[2].content.first == 0,
            let fields = DER.children(top[0].content), fields.first?.tag == 0xA0, fields.count >= 7,
            let validity = DER.children(fields[4].content), validity.count == 2,
            let notBefore = time(tag: validity[0].tag, validity[0].content),
            let notAfter = time(tag: validity[1].tag, validity[1].content)
        else { return nil }
        return CAInfo(
            tbs: DER.tlv(top[0].tag, Array(top[0].content)), signature: Array(top[2].content.dropFirst()),
            issuer: DER.tlv(fields[3].tag, Array(fields[3].content)),
            subject: DER.tlv(fields[5].tag, Array(fields[5].content)), notBefore: notBefore, notAfter: notAfter,
            isCA: isCAFlag(fields))
    }

    private static func isCAFlag(_ fields: [(tag: UInt8, content: ArraySlice<UInt8>)]) -> Bool {
        guard let wrapper = fields.first(where: { $0.tag == 0xA3 }), let list = DER.read(wrapper.content),
            let extensions = DER.children(list.content)
        else { return false }
        let oid = Array(DER.oid(oidBasicConstraints).dropFirst(2))
        for e in extensions {
            guard let parts = DER.children(e.content), let id = parts.first, Array(id.content) == oid,
                let value = parts.last, value.tag == 0x04, let body = DER.read(value.content),
                let items = DER.children(body.content), let flag = items.first
            else { continue }
            return flag.tag == 0x01 && flag.content.first == 0xFF
        }
        return false
    }

    /// A UTCTime or GeneralizedTime in UTC ("...Z").
    private static func time(tag: UInt8, _ content: ArraySlice<UInt8>) -> Date? {
        let text = String(decoding: content, as: UTF8.self)
        guard text.hasSuffix("Z"), text.dropLast().allSatisfy(\.isNumber) else { return nil }
        let digits = Array(text.dropLast())
        var parts: [Int] = []
        let year: Int
        let rest: [Character]
        switch (tag, digits.count) {
        case (0x17, 12):
            guard let yy = Int(String(digits[0..<2])) else { return nil }
            year = yy < 50 ? 2000 + yy : 1900 + yy
            rest = Array(digits[2...])
        case (0x18, 14):
            guard let yyyy = Int(String(digits[0..<4])) else { return nil }
            year = yyyy
            rest = Array(digits[4...])
        default: return nil
        }
        for i in stride(from: 0, to: rest.count, by: 2) {
            guard let n = Int(String(rest[i..<i + 2])) else { return nil }
            parts.append(n)
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return calendar.date(
            from: DateComponents(
                year: year, month: parts[0], day: parts[1], hour: parts[2], minute: parts[3], second: parts[4]))
    }
}
