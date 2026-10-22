import Foundation
import Testing

@testable import ColimaBar

@Suite struct DomainPageTests {
    private func text(_ kind: DomainPage.Kind, headOnly: Bool = false) -> String {
        String(decoding: DomainPage.response(kind, headOnly: headOnly), as: UTF8.self)
    }

    @Test func eachKindHasItsStatusLine() {
        let cases: [(DomainPage.Kind, String)] = [
            (.badRequest, "HTTP/1.1 400 Bad Request"),
            (.notFound(host: "a.localhost", profile: "default", known: []), "HTTP/1.1 404 Not Found"),
            (.foreign, "HTTP/1.1 404 Not Found"),
            (.timeout, "HTTP/1.1 408 Request Timeout"),
            (.headTooLarge, "HTTP/1.1 431 Request Header Fields Too Large"),
            (
                .upstreamDown(host: "a.localhost", container: "web", containerPort: 3000, hostPort: 49153),
                "HTTP/1.1 502 Bad Gateway"
            ),
            (.selfLoop(host: "a.localhost", container: "web", hostPort: 80), "HTTP/1.1 502 Bad Gateway"),
            (.vmStopped(profile: "default"), "HTTP/1.1 503 Service Unavailable"),
            (.busy, "HTTP/1.1 503 Service Unavailable"),
        ]
        for (kind, line) in cases { #expect(text(kind).hasPrefix(line + "\r\n"), "\(kind)") }
    }

    @Test func theHeadersAreSafe() {
        let t = text(.badRequest)
        for h in [
            "Content-Type: text/html; charset=utf-8", "Cache-Control: no-store", "X-Content-Type-Options: nosniff",
            "Content-Security-Policy: default-src 'none'; style-src 'unsafe-inline'", "Connection: close",
        ] { #expect(t.contains(h + "\r\n"), "\(h)") }
    }

    @Test func contentLengthMatchesTheBody() throws {
        let data = DomainPage.response(.badRequest, headOnly: false)
        let split = try #require(data.range(of: Data("\r\n\r\n".utf8)))
        let head = String(decoding: data[..<split.lowerBound], as: UTF8.self)
        let body = data[split.upperBound...]
        let length = try #require(
            head.components(separatedBy: "Content-Length: ").last?.components(separatedBy: "\r\n").first)
        #expect(Int(length) == body.count)
    }

    @Test func aHeadResponseKeepsTheLengthAndHasNoBody() throws {
        let full = DomainPage.response(.vmStopped(profile: "p"), headOnly: false)
        let head = DomainPage.response(.vmStopped(profile: "p"), headOnly: true)
        let split = try #require(head.range(of: Data("\r\n\r\n".utf8)))
        #expect(split.upperBound == head.endIndex)
        let fullText = String(decoding: full, as: UTF8.self)
        let headText = String(decoding: head, as: UTF8.self)
        let length = { (s: String) in s.components(separatedBy: "\r\n").first { $0.hasPrefix("Content-Length:") } }
        #expect(length(fullText) == length(headText))
        #expect(head.count < full.count)
    }

    @Test func valuesAreEscaped() {
        let t = text(
            .notFound(host: "<script>alert(1)</script>.localhost", profile: "a\"b", known: ["<b>x</b>.localhost"]))
        #expect(!t.contains("<script>"))
        #expect(!t.contains("<b>x"))
        #expect(t.contains("&lt;script&gt;"))
        #expect(t.contains("a&quot;b"))
    }

    @Test func aForeignHostGetsNoList() {
        let t = text(.foreign)
        #expect(t.contains("Unknown address"))
        #expect(!t.contains("Names that work now"))
    }

    @Test func aMissingNameShowsTheKnownNames() {
        let t = text(.notFound(host: "x.localhost", profile: "default", known: ["web.shop.localhost:8080"]))
        #expect(t.contains("No container at x.localhost"))
        #expect(t.contains("Names that work now:"))
        #expect(t.contains("href=\"http://web.shop.localhost:8080/\""))
        #expect(
            text(.notFound(host: "x.localhost", profile: "default", known: [])).contains(
                "No running container publishes a web port."))
    }

    @Test func aSecureRequestGetsLinksWithHTTPS() {
        let t = text(.notFound(host: "x.localhost", profile: "default", known: ["web.localhost:8443"], secure: true))
        #expect(t.contains("href=\"https://web.localhost:8443/\""))
        #expect(!t.contains("href=\"http://"))
    }

    @Test func theListHoldsAtMost50Names() {
        let known = (0..<80).map { "n\($0).localhost" }
        let t = text(.notFound(host: "x.localhost", profile: "default", known: known))
        #expect(t.contains("n49.localhost"))
        #expect(!t.contains("n50.localhost"))
    }

    @Test func theBadGatewayPageNamesTheContainerAndThePorts() {
        let t = text(.upstreamDown(host: "web.localhost", container: "web", containerPort: 3000, hostPort: 49153))
        #expect(t.contains("web.localhost points to the container web on port 3000 (localhost:49153)"))
    }

    @Test func theSelfLoopPageNamesTheProxyPort() {
        let t = text(.selfLoop(host: "web.localhost", container: "web", hostPort: 8080))
        #expect(t.contains("That is the port of this proxy."))
        #expect(t.contains("localhost:8080"))
    }
}
