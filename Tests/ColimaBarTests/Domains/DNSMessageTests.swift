import Testing

@testable import ColimaBar

@Suite struct DNSMessageTests {
    private let zone = "colima.internal"

    /// A query packet built by hand.
    private func query(
        _ name: String, type: UInt16 = 1, qclass: UInt16 = 1, id: UInt16 = 0x1234, flags: UInt16 = 0x0100,
        qdcount: UInt16 = 1, extra: [UInt8] = [], arcount: UInt16 = 0
    ) -> [UInt8] {
        var p: [UInt8] = [UInt8(id >> 8), UInt8(id & 0xFF), UInt8(flags >> 8), UInt8(flags & 0xFF)]
        p += [UInt8(qdcount >> 8), UInt8(qdcount & 0xFF), 0, 0, 0, 0, UInt8(arcount >> 8), UInt8(arcount & 0xFF)]
        p += encode(name)
        p += [UInt8(type >> 8), UInt8(type & 0xFF), UInt8(qclass >> 8), UInt8(qclass & 0xFF)]
        return p + extra
    }

    private func encode(_ name: String) -> [UInt8] {
        var out: [UInt8] = []
        for label in name.split(separator: ".") {
            out.append(UInt8(label.utf8.count))
            out += Array(label.utf8)
        }
        return out + [0]
    }

    private func flags(_ r: [UInt8]) -> UInt16 { UInt16(r[2]) << 8 | UInt16(r[3]) }
    private func rcode(_ r: [UInt8]) -> UInt8 { r[3] & 0x0F }
    private func count(_ r: [UInt8], _ at: Int) -> Int { Int(r[at]) << 8 | Int(r[at + 1]) }

    private func respond(_ p: [UInt8]) throws -> [UInt8] { try #require(DNSMessage.response(to: p, zone: zone)) }

    // MARK: Answers

    @Test func anAQueryGetsTheExactBytes() throws {
        let q = query("web.shop.colima.internal")
        let name: [UInt8] =
            [3] + Array("web".utf8) + [4] + Array("shop".utf8) + [6] + Array("colima".utf8) + [8]
            + Array("internal".utf8) + [0]
        let expected: [UInt8] =
            [0x12, 0x34, 0x85, 0x00, 0, 1, 0, 1, 0, 0, 0, 0] + name + [0, 1, 0, 1]
            + [0xC0, 0x0C, 0, 1, 0, 1, 0, 0, 0, 5, 0, 4, 127, 0, 0, 1]
        #expect(try respond(q) == expected)
    }

    @Test func anAAAAQueryGetsLoopbackV6() throws {
        let r = try respond(query("a.colima.internal", type: 28))
        #expect(count(r, 6) == 1)
        #expect(Array(r.suffix(16)) == [UInt8](repeating: 0, count: 15) + [1])
        #expect(rcode(r) == 0)
    }

    @Test func otherTypesGetNoDataAndAnyGetsBoth() throws {
        let mx = try respond(query("a.colima.internal", type: 15))
        #expect(rcode(mx) == 0 && count(mx, 6) == 0)
        let any = try respond(query("a.colima.internal", type: 255))
        #expect(count(any, 6) == 2 && rcode(any) == 0)
    }

    @Test func theQuestionKeepsItsCase() throws {
        let q = query("Web.Shop.Colima.Internal")
        let r = try respond(q)
        #expect(Array(r[12..<q.count]) == Array(q[12...]))
        #expect(count(r, 6) == 1)
    }

    @Test func theZoneApexAnswersAndOtherNamesDoNot() throws {
        #expect(count(try respond(query("colima.internal")), 6) == 1)
        let out = try respond(query("example.com"))
        #expect(rcode(out) == 3 && count(out, 6) == 0)
        #expect(rcode(try respond(query("evilcolima.internal"))) == 3)
        #expect(rcode(try respond(query("colima.internal.example.com"))) == 3)
    }

    @Test func theFlagsAreAuthoritativeWithoutRecursionAvailable() throws {
        let r = try respond(query("a.colima.internal", flags: 0x0100))
        #expect(flags(r) & 0x8000 != 0 && flags(r) & 0x0400 != 0 && flags(r) & 0x0080 == 0 && flags(r) & 0x0100 != 0)
        let norecurse = try respond(query("a.colima.internal", flags: 0))
        #expect(flags(norecurse) & 0x0100 == 0)
    }

    @Test func anEDNSRecordIsIgnoredAndNotEchoed() throws {
        let opt: [UInt8] = [0, 0, 41, 0x10, 0, 0, 0, 0, 0, 0, 0]
        let q = query("a.colima.internal", extra: opt, arcount: 1)
        let r = try respond(q)
        #expect(count(r, 10) == 0 && count(r, 6) == 1)
        #expect(r.count == 12 + encode("a.colima.internal").count + 4 + 16)
    }

    @Test func aCompressionPointerAfterTheQuestionIsNotFollowed() throws {
        // Trailing junk after the question changes nothing.
        let q = query("a.colima.internal", extra: [0xC0, 0x0C, 0xC0, 0x0C])
        #expect(count(try respond(q), 6) == 1)
    }

    // MARK: Errors

    @Test func malformedQuestionsGetFormErr() throws {
        let two = try respond(query("a.colima.internal", qdcount: 2))
        #expect(rcode(two) == 1 && two.count == 12 && count(two, 4) == 0)
        var pointer = query("a.colima.internal")
        pointer[12] = 0xC0
        pointer[13] = 0x0C
        #expect(rcode(try respond(pointer)) == 1)
        var p = Array(query("a.colima.internal").prefix(12))
        p += [64] + [UInt8](repeating: 97, count: 64) + [0, 0, 1, 0, 1]
        #expect(rcode(try respond(p)) == 1)
        let truncated = Array(query("a.colima.internal").dropLast(3))
        #expect(rcode(try respond(truncated)) == 1)
        let noEnd = Array(query("a.colima.internal").prefix(12)) + [5, 97, 98]
        #expect(rcode(try respond(noEnd)) == 1)
        let reserved = Array(query("a.colima.internal").prefix(12)) + [0x80, 0, 0, 1, 0, 1]
        #expect(rcode(try respond(reserved)) == 1)
    }

    @Test func aNameOver255BytesGetsFormErr() throws {
        var p = Array(query("a.colima.internal").prefix(12))
        for _ in 0..<5 { p += [60] + [UInt8](repeating: 97, count: 60) }
        p += [0, 0, 1, 0, 1]
        #expect(rcode(try respond(p)) == 1)
    }

    @Test func tinyHugeAndResponsePacketsAreDropped() {
        #expect(DNSMessage.response(to: [UInt8](repeating: 0, count: 11), zone: zone) == nil)
        #expect(DNSMessage.response(to: [UInt8](repeating: 0, count: 12), zone: zone) == nil)
        #expect(DNSMessage.response(to: [], zone: zone) == nil)
        let huge = query("a.colima.internal", extra: [UInt8](repeating: 0, count: 600))
        #expect(DNSMessage.response(to: huge, zone: zone) == nil)
        #expect(DNSMessage.response(to: query("a.colima.internal", flags: 0x8100), zone: zone) == nil)
        #expect(DNSMessage.parseQuery(query("a.colima.internal", flags: 0x8100)) == nil)
    }

    @Test func otherOpcodesAndClassesAreRefused() throws {
        let notimp = try respond(query("a.colima.internal", flags: 0x1100))
        #expect(rcode(notimp) == 4 && notimp.count == 12)
        let refused = try respond(query("a.colima.internal", qclass: 3))
        #expect(rcode(refused) == 5 && count(refused, 6) == 0)
        #expect(count(try respond(query("a.colima.internal", qclass: 255)), 6) == 1)
    }

    @Test func parseQueryReadsTheFields() throws {
        let q = try #require(DNSMessage.parseQuery(query("Web.Colima.Internal", type: 28, id: 0xBEEF)))
        #expect(q.id == 0xBEEF && q.name == "web.colima.internal" && q.type == 28 && q.qclass == 1)
        #expect(q.questionEnd == 12 + encode("Web.Colima.Internal").count + 4)
    }

    @Test func randomGarbageNeverCrashes() {
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<2000 {
            let n = Int.random(in: 0...80, using: &generator)
            let bytes = (0..<n).map { _ in UInt8.random(in: 0...255, using: &generator) }
            _ = DNSMessage.response(to: bytes, zone: zone)
        }
    }
}
