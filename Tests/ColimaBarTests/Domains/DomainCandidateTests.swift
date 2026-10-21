import Foundation
import Testing

@testable import ColimaBar

@Suite struct DomainCandidateTests {
    private func api(
        name: String = "/web", state: String = "running", ports: String = "[]", labels: String = "{}",
        created: Int = 100
    ) throws -> APIContainer {
        let json = """
            {"Id":"abc123def456789","Names":["\(name)"],"Image":"img","State":"\(state)","Status":"Up",\
            "Ports":\(ports),"Labels":\(labels),"Created":\(created)}
            """
        return try JSONDecoder().decode(APIContainer.self, from: Data(json.utf8))
    }

    private func port(_ ip: String, _ pub: Int, _ priv: Int, _ type: String = "tcp") -> String {
        #"{"IP":"\#(ip)","PublicPort":\#(pub),"PrivatePort":\#(priv),"Type":"\#(type)"}"#
    }

    @Test func aRunningContainerBecomesACandidate() throws {
        let c = try #require(DomainCandidate(try api(ports: "[\(port("0.0.0.0", 49153, 3000))]")))
        #expect(c.id == "abc123def456789")
        #expect(c.name == "web")
        #expect(c.created == 100)
        #expect(c.ports == [.init(containerPort: 3000, hostPort: 49153)])
        #expect(c.project == nil)
        #expect(c.domains == .none)
    }

    @Test func aContainerThatDoesNotRunIsNoCandidate() throws {
        #expect(DomainCandidate(try api(state: "exited")) == nil)
        #expect(DomainCandidate(try api(state: "paused")) == nil)
    }

    @Test func testcontainersAndHelpersAreNoCandidates() throws {
        #expect(DomainCandidate(try api(labels: #"{"org.testcontainers":"true"}"#)) == nil)
        #expect(DomainCandidate(try api(name: "/colimabar-debug-0123456789ab")) == nil)
        #expect(DomainCandidate(try api(labels: #"{"\#(HelperImage.label)":"1"}"#)) == nil)
    }

    @Test func onlyTCPPortsOnThisMacCount() throws {
        let ports = [
            port("0.0.0.0", 1001, 80), port("::", 1001, 80), port("127.0.0.1", 1002, 81),
            port("::1", 1003, 82), port("0.0.0.0", 1004, 83, "udp"), port("192.168.1.5", 1005, 84),
            port("", 1006, 85), port("0.0.0.0", 0, 86), port("0.0.0.0", 1007, 0),
        ].joined(separator: ",")
        let c = try #require(DomainCandidate(try api(ports: "[\(ports)]")))
        #expect(
            c.ports == [
                .init(containerPort: 80, hostPort: 1001), .init(containerPort: 81, hostPort: 1002),
                .init(containerPort: 82, hostPort: 1003),
            ])
    }

    @Test func portsHaveAFixedOrder() throws {
        let ports = [port("0.0.0.0", 9, 80), port("0.0.0.0", 8, 80), port("0.0.0.0", 7, 22)].joined(separator: ",")
        let c = try #require(DomainCandidate(try api(ports: "[\(ports)]")))
        #expect(c.ports.map(\.containerPort) == [22, 80, 80])
        #expect(c.ports.map(\.hostPort) == [7, 8, 9])
    }

    @Test func composeLabelsGiveTheProjectAndTheService() throws {
        let labels = """
            {"com.docker.compose.project":"shop","com.docker.compose.service":"web",\
            "com.docker.compose.container-number":"2"}
            """
        let c = try #require(DomainCandidate(try api(labels: labels)))
        #expect(c.project == "shop")
        #expect(c.service == "web")
        #expect(c.number == 2)
    }

    @Test func anInvalidProjectNameCountsAsStandalone() throws {
        let labels = #"{"com.docker.compose.project":"Bad Project","com.docker.compose.service":"web"}"#
        let c = try #require(DomainCandidate(try api(labels: labels)))
        #expect(c.project == nil)
        #expect(c.service == nil)
    }

    @Test func thePortLabelBeatsTheOrbStackLabel() throws {
        let both = try #require(
            DomainCandidate(try api(labels: #"{"dev.colimabar.port":"3000","dev.orbstack.http-port":"4000"}"#)))
        #expect(both.labelPort == 3000)
        let orb = try #require(DomainCandidate(try api(labels: #"{"dev.orbstack.http-port":"4000"}"#)))
        #expect(orb.labelPort == 4000)
        let bad = try #require(
            DomainCandidate(try api(labels: #"{"dev.colimabar.port":"0","dev.orbstack.http-port":"4000"}"#)))
        #expect(bad.labelPort == 4000)
        let none = try #require(DomainCandidate(try api(labels: #"{"dev.colimabar.port":"http"}"#)))
        #expect(none.labelPort == nil)
    }

    @Test func aMissingCreatedFieldIsZero() throws {
        let json = #"{"Id":"x","Names":["/a"],"Image":"i","State":"running","Status":"Up"}"#
        let c = try #require(DomainCandidate(try JSONDecoder().decode(APIContainer.self, from: Data(json.utf8))))
        #expect(c.created == 0)
    }

    @Test func parseDomainsReadsOffAndNames() {
        #expect(DomainCandidate.parseDomains(nil) == .none)
        #expect(DomainCandidate.parseDomains("off") == .off)
        #expect(DomainCandidate.parseDomains(" OFF ") == .off)
        #expect(
            DomainCandidate.parseDomains("a.localhost,admin.shop.localhost@8081")
                == .names([
                    .init(name: "a.localhost", containerPort: nil),
                    .init(name: "admin.shop.localhost", containerPort: 8081),
                ]))
        #expect(
            DomainCandidate.parseDomains(" A.Localhost , b.localhost ")
                == .names([
                    .init(name: "a.localhost", containerPort: nil), .init(name: "b.localhost", containerPort: nil),
                ]))
    }

    @Test func parseDomainsDropsBadEntries() {
        #expect(DomainCandidate.parseDomains("*.x.localhost") == .none)
        #expect(DomainCandidate.parseDomains("a.localhost@0") == .none)
        #expect(DomainCandidate.parseDomains("a.localhost@99999") == .none)
        #expect(DomainCandidate.parseDomains("a.localhost@x") == .none)
        #expect(DomainCandidate.parseDomains("a_b.localhost") == .none)
        #expect(DomainCandidate.parseDomains("a.localhost:80") == .none)
        #expect(DomainCandidate.parseDomains("127.0.0.1") == .none)
        #expect(
            DomainCandidate.parseDomains("*.x.localhost,ok.localhost")
                == .names([
                    .init(name: "ok.localhost", containerPort: nil)
                ]))
    }

    @Test func parseDomainsKeepsAtMost16Entries() {
        let list = (0..<17).map { "n\($0).localhost" }.joined(separator: ",")
        guard case .names(let entries) = DomainCandidate.parseDomains(list) else {
            Issue.record("no names")
            return
        }
        #expect(entries.count == 16)
        #expect(entries.last?.name == "n15.localhost")
    }
}
