import Foundation
import Testing

@testable import ColimaBar

@Suite struct DomainRoutesTests {
    private typealias C = DomainCandidate
    private typealias P = DomainCandidate.PortMap

    private func build(_ list: [C], vmRunning: Bool = true, suffixes: [String] = ["localhost"]) -> DomainRoutes {
        DomainRoutes.build(list, suffixes: suffixes, profile: "default", vmRunning: vmRunning)
    }

    private func compose(
        _ id: String, project: String = "shop", service: String = "web", number: Int? = 1, created: Int64 = 1,
        ports: [P] = [P(containerPort: 80, hostPort: 8000)], labelPort: Int? = nil, domains: C.Domains = .none
    ) -> C {
        C(
            id: id, name: "\(project)-\(service)-\(number ?? 1)", created: created, project: project, service: service,
            number: number, ports: ports, labelPort: labelPort, domains: domains)
    }

    private func standalone(
        _ id: String, name: String, created: Int64 = 1, ports: [P] = [P(containerPort: 80, hostPort: 8000)],
        labelPort: Int? = nil, domains: C.Domains = .none
    ) -> C {
        C(id: id, name: name, created: created, ports: ports, labelPort: labelPort, domains: domains)
    }

    // MARK: Naming

    @Test func composeServicesAreNamedServiceDotProject() {
        let t = build([compose("a")])
        #expect(t.routes["web.shop"]?.containerID == "a")
        #expect(t.primaryName("a") == "web.shop")
        #expect(t.projects["shop"] == ["web.shop"])
        #expect(t.count == 1)
    }

    @Test func standaloneContainersUseTheirName() {
        let t = build([standalone("a", name: "My_App")])
        #expect(t.routes["my-app"]?.containerID == "a")
        #expect(t.projects.isEmpty)
    }

    @Test func replicasGetNumbersAndTheLowestKeepsThePlainName() {
        let t = build([
            compose("a", number: 1, created: 1), compose("b", number: 2, created: 2),
        ])
        #expect(t.routes["web-1.shop"]?.containerID == "a")
        #expect(t.routes["web-2.shop"]?.containerID == "b")
        #expect(t.routes["web.shop"]?.containerID == "a")
        #expect(t.names["a"] == ["web-1.shop", "web.shop"])
        #expect(t.names["b"] == ["web-2.shop"])
        #expect(t.projects["shop"] == ["web-1.shop", "web-2.shop", "web.shop"])
    }

    @Test func aSingleReplicaKeepsThePlainName() {
        let t = build([compose("a", number: 3)])
        #expect(t.routes["web.shop"]?.containerID == "a")
        #expect(t.routes["web-3.shop"] == nil)
    }

    // MARK: Ports

    private func pick(_ ports: [(Int, Int)], label: Int? = nil) -> P? {
        DomainRoutes.pickPort(
            C(
                id: "x", name: "x",
                ports: ports.sorted { ($0.0, $0.1) < ($1.0, $1.1) }.map { P(containerPort: $0.0, hostPort: $0.1) },
                labelPort: label))
    }

    @Test func theLabelPortWins() {
        #expect(pick([(80, 1), (3000, 2)], label: 3000) == P(containerPort: 3000, hostPort: 2))
    }

    @Test func thePreferredOrderDecides() {
        #expect(pick([(443, 1), (3000, 2), (8443, 3)]) == P(containerPort: 3000, hostPort: 2))
        #expect(pick([(3000, 2), (80, 1)]) == P(containerPort: 80, hostPort: 1))
        #expect(pick([(8443, 3), (443, 1)]) == P(containerPort: 443, hostPort: 1))
        #expect(pick([(9000, 5), (3000, 2)]) == P(containerPort: 3000, hostPort: 2))
    }

    @Test func otherwiseTheLowestWebPort() {
        #expect(pick([(9100, 1), (9000, 2)]) == P(containerPort: 9000, hostPort: 2))
        #expect(pick([(5432, 1), (9000, 2)]) == P(containerPort: 9000, hostPort: 2))
        #expect(pick([(9000, 5432)]) == nil)
    }

    @Test func aDatabaseHasNoName() {
        let t = build([standalone("a", name: "db", ports: [P(containerPort: 5432, hostPort: 5432)])])
        #expect(t.routes.isEmpty)
        #expect(t.names.isEmpty)
        #expect(t.publishedHostPorts == [5432])
    }

    @Test func severalHostPortsGiveTheLowest() {
        let t = build([
            standalone("a", name: "w", ports: [P(containerPort: 80, hostPort: 5), P(containerPort: 80, hostPort: 9)])
        ])
        #expect(t.routes["w"]?.hostPort == 5)
    }

    @Test func aLabelPortThatIsNotPublishedGivesANoteAndNoRoute() {
        let t = build([standalone("a", name: "w", labelPort: 9999)])
        #expect(t.routes.isEmpty)
        #expect(t.notes["a"] == [.labelPortNotPublished(9999)])
    }

    @Test func routesToTLSPortsUseUpstreamTLS() {
        let t = build([
            standalone("a", name: "a", ports: [P(containerPort: 443, hostPort: 1)]),
            standalone("b", name: "b", ports: [P(containerPort: 8443, hostPort: 2)]),
            standalone("c", name: "c", ports: [P(containerPort: 80, hostPort: 3)]),
        ])
        #expect(t.routes["a"]?.upstreamTLS == true)
        #expect(t.routes["b"]?.upstreamTLS == true)
        #expect(t.routes["c"]?.upstreamTLS == false)
    }

    // MARK: Labels

    @Test func labelNamesAddToTheDerivedNames() {
        let c = compose("a", domains: .names([.init(name: "admin.shop.localhost", containerPort: nil)]))
        let t = build([c])
        #expect(t.routes["admin.shop"]?.containerID == "a")
        #expect(t.routes["web.shop"]?.containerID == "a")
        #expect(t.names["a"] == ["web.shop", "admin.shop"])
    }

    @Test func aLabelNameCanPickItsPort() {
        let ports = [P(containerPort: 80, hostPort: 8000), P(containerPort: 8081, hostPort: 8001)]
        let c = compose("a", ports: ports, domains: .names([.init(name: "admin.localhost", containerPort: 8081)]))
        let t = build([c])
        #expect(t.routes["admin"]?.hostPort == 8001)
        #expect(t.routes["web.shop"]?.hostPort == 8000)
    }

    @Test func aLabelNameWithAPortThatIsNotPublishedDrops() {
        let c = compose("a", domains: .names([.init(name: "admin.localhost", containerPort: 8081)]))
        #expect(build([c]).routes["admin"] == nil)
    }

    @Test func aNameUnderAnotherSuffixIsIgnored() {
        let c = compose("a", domains: .names([.init(name: "admin.example.com", containerPort: nil)]))
        let t = build([c])
        #expect(t.routes.count == 1)
    }

    @Test func offGivesNoNameAtAll() {
        let t = build([compose("a", domains: .off)])
        #expect(t.routes.isEmpty)
        #expect(t.names.isEmpty)
        #expect(t.publishedHostPorts == [8000])
    }

    @Test func theSelfTestNameIsNeverARoute() {
        let c = standalone(
            "a", name: DomainName.selfTestLabel,
            domains: .names([.init(name: "\(DomainName.selfTestLabel).localhost", containerPort: nil)]))
        #expect(build([c]).routes.isEmpty)
    }

    // MARK: Collisions

    @Test func collisionsDoNotDependOnTheOrder() {
        let list = [
            standalone("c", name: "web", created: 3), standalone("a", name: "web", created: 1),
            standalone("b", name: "web", created: 2),
        ]
        let orders = [[0, 1, 2], [0, 2, 1], [1, 0, 2], [1, 2, 0], [2, 0, 1], [2, 1, 0]]
        let first = build(orders[0].map { list[$0] })
        #expect(first.routes["web"]?.containerID == "a")
        for order in orders { #expect(build(order.map { list[$0] }) == first, "\(order)") }
    }

    @Test func aLabelNameBeatsADerivedName() {
        let older = standalone("a", name: "web", created: 1)
        let newer = standalone(
            "b", name: "other", created: 2, domains: .names([.init(name: "web.localhost", containerPort: nil)]))
        let t = build([older, newer])
        #expect(t.routes["web"]?.containerID == "b")
        #expect(t.notes["a"] == [.taken(name: "web", by: "other")])
    }

    @Test func theOlderContainerWins() {
        let t = build([standalone("b", name: "web", created: 2), standalone("a", name: "web", created: 1)])
        #expect(t.routes["web"]?.containerID == "a")
        #expect(t.notes["b"] == [.taken(name: "web", by: "web")])
        #expect(t.names["b"] == nil)
        #expect(t.notes["a"] == nil)
    }

    @Test func aContainerThatClaimsANameTwiceIsNoLoser() {
        let c = standalone("a", name: "web", domains: .names([.init(name: "web.localhost", containerPort: nil)]))
        let t = build([c])
        #expect(t.notes["a"] == nil)
        #expect(t.names["a"] == ["web"])
    }

    // MARK: Resolve

    @Test func resolveFindsExactNamesAndParents() {
        let t = build([compose("a")])
        guard case .route(let r) = t.resolve(host: "web.shop.localhost") else {
            Issue.record("no route")
            return
        }
        #expect(r.hostPort == 8000)
        #expect(t.resolve(host: "WEB.shop.localhost:8080") == .route(r))
        #expect(t.resolve(host: "api.web.shop.localhost") == .route(r))
        #expect(t.resolve(host: "a.b.c.web.shop.localhost") == .route(r))
    }

    @Test func resolveReportsWhatIsMissing() {
        let t = build([compose("a")])
        #expect(t.resolve(host: "shop.localhost") == .unknown(relative: "shop"))
        #expect(t.resolve(host: "nope.localhost") == .unknown(relative: "nope"))
        #expect(t.resolve(host: "localhost") == .unknown(relative: ""))
        #expect(t.resolve(host: "evil.com") == .foreign)
        #expect(t.resolve(host: "127.0.0.1") == .foreign)
        #expect(t.resolve(host: "[::1]") == .foreign)
        #expect(t.resolve(host: "") == .foreign)
        #expect(t.resolve(host: "web.shop.localhost.evil.com") == .foreign)
    }

    @Test func aStoppedVMGivesNoRoutes() {
        let t = build([compose("a")], vmRunning: false)
        #expect(t.resolve(host: "web.shop.localhost") == .vmStopped)
        #expect(t.resolve(host: "evil.com") == .foreign)
    }

    @Test func emptyRoutesResolveToUnknown() {
        #expect(DomainRoutes.empty.vmRunning == false)
        #expect(DomainRoutes.empty.resolve(host: "a.localhost") == .vmStopped)
    }

    @Test func publishedHostPortsListEveryRunningCandidate() {
        let t = build([
            standalone("a", name: "a", ports: [P(containerPort: 80, hostPort: 1), P(containerPort: 22, hostPort: 2)]),
            standalone("b", name: "b", ports: [P(containerPort: 3000, hostPort: 3)]),
        ])
        #expect(t.publishedHostPorts == [1, 2, 3])
    }
}
