import Foundation
import Testing

@testable import ColimaBar

@Suite struct PortLinkTests {
    private func url(_ host: Int, _ container: Int = 80, _ proto: String = "tcp", _ ip: String = "0.0.0.0") -> String? {
        PortLink.url(hostPort: host, containerPort: container, proto: proto, hostIP: ip)?.absoluteString
    }

    @Test func aWebPortOpensOnLocalhost() {
        #expect(url(18080) == "http://localhost:18080")
    }

    @Test(arguments: ["", "0.0.0.0", "::", "127.0.0.1", "::1"])
    func aLocalBindingHasALink(ip: String) {
        #expect(url(8080, 80, "tcp", ip) == "http://localhost:8080")
    }

    @Test func aBindingToAnotherAddressHasNoLink() {
        #expect(url(8080, 80, "tcp", "192.168.1.5") == nil)
        #expect(url(8080, 80, "tcp", "example.org") == nil)
    }

    @Test func onlyTCPHasALink() {
        #expect(url(8080, 80, "udp") == nil)
        #expect(url(8080, 80, "sctp") == nil)
        #expect(url(8080, 80, "TCP") == "http://localhost:8080")
    }

    @Test func aContainerPortOf443Or8443UsesHTTPS() {
        #expect(url(8443, 443) == "https://localhost:8443")
        #expect(url(9443, 8443) == "https://localhost:9443")
    }

    @Test(arguments: [22, 25, 53, 1433, 1521, 2181, 3306, 4222, 5432, 5672, 6379, 9092, 11211, 27017])
    func aServicePortOtherThanHTTPHasNoLink(port: Int) {
        #expect(url(port, port) == nil)
        #expect(url(18000, port) == nil)
        #expect(url(port, 80) == nil)
    }

    @Test func aHostPortOutsideTheRangeHasNoLink() {
        #expect(url(0) == nil)
        #expect(url(65536) == nil)
        #expect(url(-1) == nil)
        #expect(url(65535) == "http://localhost:65535")
    }
}
