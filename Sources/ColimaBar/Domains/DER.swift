import Foundation

/// A small encoder for DER, the byte format of X.509 certificates. Pure: no
/// I/O. It writes only what `X509Builder` needs.
enum DER {
    static func len(_ n: Int) -> [UInt8] {
        if n < 0x80 { return [UInt8(n)] }
        var value = n
        var out: [UInt8] = []
        while value > 0 {
            out.insert(UInt8(value & 0xFF), at: 0)
            value >>= 8
        }
        return [0x80 | UInt8(out.count)] + out
    }

    static func tlv(_ tag: UInt8, _ body: [UInt8]) -> [UInt8] { [tag] + len(body.count) + body }
    static func seq(_ items: [UInt8]...) -> [UInt8] { tlv(0x30, items.flatMap { $0 }) }
    static func seqOf(_ items: [[UInt8]]) -> [UInt8] { tlv(0x30, items.flatMap { $0 }) }
    static func set(_ items: [UInt8]...) -> [UInt8] { tlv(0x31, items.flatMap { $0 }) }

    /// An INTEGER from big-endian bytes. Leading zeros go, and a zero byte
    /// comes back in front of a value whose top bit is set (it stays positive).
    static func int(_ bytes: [UInt8]) -> [UInt8] {
        var b = Array(bytes.drop { $0 == 0 })
        if b.isEmpty { b = [0] }
        if b[0] & 0x80 != 0 { b.insert(0, at: 0) }
        return tlv(0x02, b)
    }

    static func int(_ value: Int) -> [UInt8] {
        int(withUnsafeBytes(of: UInt64(max(value, 0)).bigEndian, Array.init))
    }

    static func bool(_ value: Bool) -> [UInt8] { tlv(0x01, [value ? 0xFF : 0x00]) }

    /// An OBJECT IDENTIFIER from its dotted text, such as `2.5.29.17`.
    static func oid(_ dotted: String) -> [UInt8] {
        let parts = dotted.split(separator: ".").compactMap { Int($0) }
        precondition(parts.count >= 2, "An OID has at least two arcs")
        var out: [UInt8] = [UInt8(parts[0] * 40 + parts[1])]
        for var value in parts.dropFirst(2) {
            var chunk: [UInt8] = [UInt8(value & 0x7F)]
            value >>= 7
            while value > 0 {
                chunk.insert(UInt8(value & 0x7F) | 0x80, at: 0)
                value >>= 7
            }
            out += chunk
        }
        return tlv(0x06, out)
    }

    static func utf8(_ text: String) -> [UInt8] { tlv(0x0C, Array(text.utf8)) }
    static func octets(_ bytes: [UInt8]) -> [UInt8] { tlv(0x04, bytes) }
    static func bits(_ bytes: [UInt8], unused: UInt8 = 0) -> [UInt8] { tlv(0x03, [unused] + bytes) }

    /// A context-specific tag `[n]`, constructed or primitive.
    static func ctx(_ n: UInt8, constructed: Bool = true, _ body: [UInt8]) -> [UInt8] {
        tlv((constructed ? 0xA0 : 0x80) | n, body)
    }

    /// UTCTime `yyMMddHHmmssZ` before 2050, else GeneralizedTime
    /// `yyyyMMddHHmmssZ`. It uses `Calendar` in UTC and no `DateFormatter`,
    /// so it is thread safe and gives the same bytes everywhere.
    static func time(_ date: Date) -> [UInt8] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let year = c.year ?? 1970
        func two(_ n: Int?) -> String { String(format: "%02d", n ?? 0) }
        let rest = two(c.month) + two(c.day) + two(c.hour) + two(c.minute) + two(c.second) + "Z"
        if year < 2050 { return tlv(0x17, Array((two(year % 100) + rest).utf8)) }
        return tlv(0x18, Array((String(format: "%04d", year) + rest).utf8))
    }

    // MARK: - Reading

    /// One element: its tag, its content and the bytes after it. nil for a
    /// truncated or oversized element.
    static func read(_ bytes: ArraySlice<UInt8>) -> (tag: UInt8, content: ArraySlice<UInt8>, rest: ArraySlice<UInt8>)? {
        guard let tag = bytes.first, bytes.count >= 2 else { return nil }
        var index = bytes.startIndex + 1
        var length = Int(bytes[index])
        index += 1
        if length & 0x80 != 0 {
            let count = length & 0x7F
            guard (1...4).contains(count), bytes.endIndex - index >= count else { return nil }
            length = 0
            for _ in 0..<count {
                length = length << 8 | Int(bytes[index])
                index += 1
            }
        }
        guard length >= 0, bytes.endIndex - index >= length else { return nil }
        return (tag, bytes[index..<index + length], bytes[(index + length)...])
    }

    /// The elements one level down in `bytes`.
    static func children(_ bytes: ArraySlice<UInt8>) -> [(tag: UInt8, content: ArraySlice<UInt8>)]? {
        var out: [(UInt8, ArraySlice<UInt8>)] = []
        var rest = bytes
        while !rest.isEmpty {
            guard let element = read(rest) else { return nil }
            out.append((element.tag, element.content))
            rest = element.rest
        }
        return out
    }
}
