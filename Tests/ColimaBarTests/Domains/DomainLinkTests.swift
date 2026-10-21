import Testing

@testable import ColimaBar

@Suite struct DomainLinkTests {
    @Test func port80IsLeftOut() {
        let url = DomainLink.url(relative: "web.shop", suffix: "localhost", secure: false, port: 80)
        #expect(url?.absoluteString == "http://web.shop.localhost/")
    }

    @Test func otherPortsStay() {
        let url = DomainLink.url(relative: "web.shop", suffix: "localhost", secure: false, port: 8080)
        #expect(url?.absoluteString == "http://web.shop.localhost:8080/")
    }

    @Test func port443IsLeftOutForHTTPS() {
        #expect(
            DomainLink.url(relative: "a", suffix: "localhost", secure: true, port: 443)?.absoluteString
                == "https://a.localhost/")
        #expect(
            DomainLink.url(relative: "a", suffix: "localhost", secure: true, port: 80)?.absoluteString
                == "https://a.localhost:80/")
    }

    @Test func anEmptyNameIsTheSuffix() {
        #expect(DomainLink.host(relative: "", suffix: "localhost") == "localhost")
        #expect(DomainLink.host(relative: "a.b", suffix: "localhost") == "a.b.localhost")
    }
}
