import Foundation
import Testing

@testable import ColimaBar

@Suite struct DERTests {
    @Test func lengthsUseTheShortAndTheLongForm() {
        #expect(DER.len(0) == [0x00])
        #expect(DER.len(127) == [0x7F])
        #expect(DER.len(128) == [0x81, 0x80])
        #expect(DER.len(255) == [0x81, 0xFF])
        #expect(DER.len(256) == [0x82, 0x01, 0x00])
        #expect(DER.len(65536) == [0x83, 0x01, 0x00, 0x00])
    }

    @Test func integersStayPositiveAndDropLeadingZeros() {
        #expect(DER.int([0x80]) == [0x02, 0x02, 0x00, 0x80])
        #expect(DER.int(0) == [0x02, 0x01, 0x00])
        #expect(DER.int([0, 0, 5]) == [0x02, 0x01, 0x05])
        #expect(DER.int([]) == [0x02, 0x01, 0x00])
        #expect(DER.int(2) == [0x02, 0x01, 0x02])
        #expect(DER.int(256) == [0x02, 0x02, 0x01, 0x00])
        #expect(DER.int([0x7F, 0xFF]) == [0x02, 0x02, 0x7F, 0xFF])
    }

    @Test func objectIdentifiersUseBase128() {
        #expect(DER.oid("1.2.840.10045.4.3.2") == [0x06, 0x08, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x04, 0x03, 0x02])
        #expect(DER.oid("2.5.29.17") == [0x06, 0x03, 0x55, 0x1D, 0x11])
        #expect(DER.oid("1.3.6.1.5.5.7.3.1") == [0x06, 0x08, 0x2B, 0x06, 0x01, 0x05, 0x05, 0x07, 0x03, 0x01])
    }

    private func date(_ iso: String) -> Date { ISO8601DateFormatter().date(from: iso) ?? .distantPast }

    @Test func timesAreUTCTimeBefore2050AndGeneralizedTimeFrom2050() {
        #expect(DER.time(date("2026-10-21T12:00:00Z")) == [0x17, 0x0D] + Array("261021120000Z".utf8))
        #expect(DER.time(date("2049-12-31T23:59:59Z")) == [0x17, 0x0D] + Array("491231235959Z".utf8))
        #expect(DER.time(date("2050-01-01T00:00:00Z")) == [0x18, 0x0F] + Array("20500101000000Z".utf8))
        #expect(DER.time(date("1999-01-02T03:04:05Z")) == [0x17, 0x0D] + Array("990102030405Z".utf8))
    }

    @Test func aTimeDoesNotDependOnTheTimeZoneOfTheMac() {
        let before = NSTimeZone.default
        defer { NSTimeZone.default = before }
        NSTimeZone.default = TimeZone(identifier: "Pacific/Auckland") ?? before
        #expect(DER.time(date("2026-10-21T23:30:00Z")) == [0x17, 0x0D] + Array("261021233000Z".utf8))
    }

    @Test func bitStringsAndOtherSimpleTypes() {
        #expect(DER.bits([0x06], unused: 1) == [0x03, 0x02, 0x01, 0x06])
        #expect(DER.bits([0xAB]) == [0x03, 0x02, 0x00, 0xAB])
        #expect(DER.bool(true) == [0x01, 0x01, 0xFF])
        #expect(DER.bool(false) == [0x01, 0x01, 0x00])
        #expect(DER.utf8("ab") == [0x0C, 0x02, 0x61, 0x62])
        #expect(DER.octets([1, 2]) == [0x04, 0x02, 1, 2])
        #expect(DER.seq([0x05, 0x00]) == [0x30, 0x02, 0x05, 0x00])
        #expect(DER.set([0x05, 0x00]) == [0x31, 0x02, 0x05, 0x00])
        #expect(DER.ctx(3, [0x05, 0x00]) == [0xA3, 0x02, 0x05, 0x00])
        #expect(DER.ctx(0, constructed: false, [0x01]) == [0x80, 0x01, 0x01])
    }

    @Test func aLongBodyGetsALongLength() {
        let body = [UInt8](repeating: 7, count: 300)
        #expect(Array(DER.octets(body).prefix(4)) == [0x04, 0x82, 0x01, 0x2C])
    }

    @Test func theReaderFindsTheElementsAndRejectsATruncatedOne() throws {
        let bytes = DER.seq(DER.int(5), DER.utf8("x"))
        let outer = try #require(DER.read(bytes[...]))
        #expect(outer.tag == 0x30 && outer.rest.isEmpty)
        let kids = try #require(DER.children(outer.content))
        #expect(kids.map(\.tag) == [0x02, 0x0C])
        #expect(DER.read(bytes.dropLast()[...]) == nil)
        #expect(DER.read([0x30][...]) == nil)
        #expect(DER.read([0x30, 0x85, 0, 0, 0, 0, 1][...]) == nil)
    }
}
