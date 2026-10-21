import Foundation
import Testing

@testable import ColimaBar

@Suite struct HTTPHeadTests {
    private func parse(_ text: String) -> Result<HTTPHead, HTTPHead.Problem> {
        HTTPHead.parse(Array(text.utf8))
    }

    private func head(_ text: String) throws -> HTTPHead {
        try parse(text).get()
    }

    @Test func aCompleteGetHasTheHostAndTheLength() throws {
        let h = "GET /a?b=1 HTTP/1.1\r\nHost: Web.Shop.localhost:8080\r\nAccept: */*\r\n\r\n"
        let parsed = try head(h + "BODY")
        #expect(parsed.method == "GET")
        #expect(parsed.target == "/a?b=1")
        #expect(parsed.version == "HTTP/1.1")
        #expect(parsed.host == "Web.Shop.localhost:8080")
        #expect(parsed.length == h.utf8.count)
        #expect(!parsed.isHead)
    }

    @Test func aHeadRequestIsRecognized() throws {
        #expect(try head("HEAD / HTTP/1.1\r\nHost: a\r\n\r\n").isHead)
    }

    @Test func aPartialHeadIsIncomplete() {
        #expect(parse("GET / HTTP/1.1\r\nHost: a\r\n") == .failure(.incomplete))
        #expect(parse("") == .failure(.incomplete))
    }

    @Test func aHeadOf64KBWithNoEndIsTooLarge() {
        let filler = String(repeating: "x", count: HTTPHead.maxBytes)
        #expect(parse("GET / HTTP/1.1\r\nX: \(filler)") == .failure(.tooLarge))
        let almost = "GET / HTTP/1.1\r\nX: " + String(repeating: "x", count: HTTPHead.maxBytes - 100)
        #expect(parse(almost) == .failure(.incomplete))
    }

    @Test func aMissingHostIsAnError() {
        #expect(parse("GET / HTTP/1.1\r\nAccept: */*\r\n\r\n") == .failure(.noHost))
        #expect(parse("GET / HTTP/1.0\r\n\r\n") == .failure(.noHost))
        #expect(parse("GET / HTTP/1.1\r\nHost:\r\n\r\n") == .failure(.noHost))
    }

    @Test func twoHostsAreAnError() {
        #expect(parse("GET / HTTP/1.1\r\nHost: a\r\nhost: b\r\n\r\n") == .failure(.duplicateHost))
    }

    @Test func theHostNameIsCaseInsensitive() throws {
        #expect(try head("GET / HTTP/1.1\r\nHOST: a.localhost\r\n\r\n").host == "a.localhost")
    }

    @Test func anAbsoluteTargetWinsOverTheHostHeader() throws {
        let h = try head("GET http://api.shop.localhost:8080/x HTTP/1.1\r\nHost: evil.com\r\n\r\n")
        #expect(h.host == "api.shop.localhost:8080")
        let noHeader = try head("GET http://a.localhost/ HTTP/1.1\r\n\r\n")
        #expect(noHeader.host == "a.localhost")
    }

    @Test func userInfoIsNoPartOfTheAuthority() throws {
        let h = try head("GET http://evil.com@a.localhost/ HTTP/1.1\r\nHost: x\r\n\r\n")
        #expect(h.host == "a.localhost")
    }

    @Test func theHTTP2PrefaceIsMalformed() {
        #expect(parse("PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n") == .failure(.malformed))
    }

    @Test func badLinesAreMalformed() {
        #expect(parse("GET /\r\nHost: a\r\n\r\n") == .failure(.malformed))
        #expect(parse("GET / HTTP/1.1\r\nHost a\r\n\r\n") == .failure(.malformed))
        #expect(parse("GET / HTTP/1.1\r\nHost: a\r\n folded\r\n\r\n") == .failure(.malformed))
        #expect(parse("GET / HTTP/1.1\r\nHost: a\r\n\tfolded\r\n\r\n") == .failure(.malformed))
        #expect(parse("GET / HTTP/3\r\nHost: a\r\n\r\n") == .failure(.malformed))
        #expect(parse("G ET / HTTP/1.1\r\nHost: a\r\n\r\n") == .failure(.malformed))
        #expect(parse("GET / HTTP/1.1\r\n: a\r\n\r\n") == .failure(.malformed))
        #expect(parse("\r\n\r\n") == .failure(.malformed))
    }
}
