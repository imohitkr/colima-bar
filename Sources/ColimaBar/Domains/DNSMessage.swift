import Foundation

/// The DNS codec of the small responder for the custom suffix. Pure: bytes in,
/// bytes out. It answers one question at a time, inside one zone: `A` with
/// 127.0.0.1, `AAAA` with ::1, nothing for other types, and REFUSED (no AA)
/// outside the zone or with an empty zone. It never follows a compression pointer, so a hostile packet
/// cannot make it loop.
enum DNSMessage {
    struct Query: Equatable, Sendable {
        let id: UInt16
        let flags: UInt16
        /// The question name, lower case, without the root dot.
        let name: String
        let type: UInt16
        let qclass: UInt16
        /// The index after the question in the packet.
        let questionEnd: Int
    }

    enum RCode: UInt8, Sendable {
        case noError = 0
        case formErr = 1
        case nxDomain = 3
        case notImp = 4
        case refused = 5
    }

    enum Parsed: Equatable, Sendable {
        /// Too short, too long, or a response. No answer.
        case drop
        /// An answer of the header only.
        case reject(RCode)
        case query(Query)
    }

    static let ttl: UInt32 = 5
    static let maxPacket = 512
    static let typeA: UInt16 = 1
    static let typeAAAA: UInt16 = 28
    static let typeANY: UInt16 = 255
    static let classIN: UInt16 = 1
    static let classANY: UInt16 = 255

    private static let headerSize = 12
    private static let flagQR: UInt16 = 0x8000
    private static let flagAA: UInt16 = 0x0400
    private static let flagRD: UInt16 = 0x0100

    // MARK: - Parse

    static func parseQuery(_ p: [UInt8]) -> Query? {
        if case .query(let q) = parse(p) { return q }
        return nil
    }

    static func parse(_ p: [UInt8]) -> Parsed {
        guard p.count > headerSize, p.count <= maxPacket else { return .drop }
        let flags = u16(p, 2)
        guard flags & flagQR == 0 else { return .drop }
        guard (flags >> 11) & 0xF == 0 else { return .reject(.notImp) }
        guard u16(p, 4) == 1 else { return .reject(.formErr) }
        // The question name: labels only. A pointer or a long label is a format error.
        var i = headerSize
        var labels: [String] = []
        var total = 1
        while true {
            guard i < p.count else { return .reject(.formErr) }
            let n = Int(p[i])
            if n == 0 {
                i += 1
                break
            }
            guard n < 64, i + 1 + n <= p.count else { return .reject(.formErr) }
            total += n + 1
            guard total <= 255 else { return .reject(.formErr) }
            labels.append(String(decoding: p[(i + 1)...(i + n)].map(lower), as: UTF8.self))
            i += 1 + n
        }
        guard i + 4 <= p.count else { return .reject(.formErr) }
        let query = Query(
            id: u16(p, 0), flags: flags, name: labels.joined(separator: "."), type: u16(p, i), qclass: u16(p, i + 2),
            questionEnd: i + 4)
        return .query(query)
    }

    // MARK: - Response

    /// The answer bytes, or nil to drop the packet.
    static func response(to p: [UInt8], zone: String) -> [UInt8]? {
        switch parse(p) {
        case .drop:
            return nil
        case .reject(let code):
            let flags = u16(p, 2)
            // The header only. It echoes the opcode and RD.
            let out = flagQR | (flags & 0x7800) | (flags & flagRD) | UInt16(code.rawValue)
            return header(id: u16(p, 0), flags: out, answers: 0, questions: 0)
        case .query(let q):
            // A name that this server is not responsible for gets REFUSED without AA.
            guard q.qclass == classIN || q.qclass == classANY else {
                return reply(p, q, .refused, [], authority: false)
            }
            let inZone = !zone.isEmpty && (q.name == zone || q.name.hasSuffix("." + zone))
            guard inZone else { return reply(p, q, .refused, [], authority: false) }
            var answers: [(UInt16, [UInt8])] = []
            if q.type == typeA || q.type == typeANY { answers.append((typeA, [127, 0, 0, 1])) }
            if q.type == typeAAAA || q.type == typeANY {
                answers.append((typeAAAA, [UInt8](repeating: 0, count: 15) + [1]))
            }
            return reply(p, q, .noError, answers)
        }
    }

    /// Copies the ID and the question verbatim (the 0x20 case stays). AA is
    /// set when `authority` is true, RA is not, and the additional section
    /// (an EDNS OPT) is dropped.
    private static func reply(
        _ p: [UInt8], _ q: Query, _ code: RCode, _ answers: [(UInt16, [UInt8])], authority: Bool = true
    ) -> [UInt8] {
        let flags = flagQR | (authority ? flagAA : 0) | (q.flags & flagRD) | UInt16(code.rawValue)
        var out = header(id: q.id, flags: flags, answers: answers.count, questions: 1)
        out += p[headerSize..<q.questionEnd]
        for (type, rdata) in answers {
            out += [0xC0, 0x0C]
            out += be16(type) + be16(classIN) + be32(ttl) + be16(UInt16(rdata.count)) + rdata
        }
        return out
    }

    private static func header(id: UInt16, flags: UInt16, answers: Int, questions: Int) -> [UInt8] {
        be16(id) + be16(flags) + be16(UInt16(questions)) + be16(UInt16(answers)) + [0, 0, 0, 0]
    }

    // MARK: - Bytes

    private static func u16(_ p: [UInt8], _ i: Int) -> UInt16 { UInt16(p[i]) << 8 | UInt16(p[i + 1]) }
    private static func be16(_ v: UInt16) -> [UInt8] { [UInt8(v >> 8), UInt8(v & 0xFF)] }
    private static func be32(_ v: UInt32) -> [UInt8] { be16(UInt16(v >> 16)) + be16(UInt16(v & 0xFFFF)) }
    private static func lower(_ b: UInt8) -> UInt8 { b >= 0x41 && b <= 0x5A ? b + 32 : b }
}
