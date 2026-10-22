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
        labelPort: Int? = nil, labelPortInvalid: String? = nil, domains: C.Domains = .none,
        droppedEntries: [String] = []
    ) -> C {
        C(
            id: id, name: name, created: created, ports: ports, labelPort: labelPort,
            labelPortInvalid: labelPortInvalid, domains: domains, droppedEntries: droppedEntries)
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

    @Test func aLabelPortOfADatabaseIsIgnoredWithANote() {
        let ports = [P(containerPort: 5432, hostPort: 5432), P(containerPort: 8080, hostPort: 9000)]
        let t = build([standalone("a", name: "db", ports: ports, labelPort: 5432)])
        #expect(t.routes["db"]?.hostPort == 9000)
        #expect(t.notes["a"] == [.labelPortNotWeb(5432)])
        let only = build([standalone("b", name: "pg", ports: [P(containerPort: 5432, hostPort: 5432)], labelPort: 5432)]
        )
        #expect(only.routes.isEmpty)
        #expect(only.notes["b"] == [.labelPortNotWeb(5432)])
    }

    @Test func aDatabasePortInANameEntryGivesNoNameAndANote() {
        let ports = [P(containerPort: 80, hostPort: 8000), P(containerPort: 6379, hostPort: 6379)]
        let c = standalone(
            "a", name: "w", ports: ports, domains: .names([.init(name: "cache.localhost", containerPort: 6379)]))
        let t = build([c])
        #expect(t.routes["cache"] == nil)
        #expect(t.routes["w"] != nil)
        #expect(t.notes["a"] == [.labelPortNotWeb(6379)])
    }

    @Test func aBadPortLabelGivesANoteAndTheAutomaticPort() {
        let t = build([standalone("a", name: "w", labelPortInvalid: "http")])
        #expect(t.routes["w"]?.hostPort == 8000)
        #expect(t.notes["a"] == [.labelPortInvalid("http")])
    }

    @Test func droppedLabelEntriesGiveNotes() {
        let c = standalone(
            "a", name: "w", domains: .names([.init(name: "other.example.com", containerPort: nil)]),
            droppedEntries: ["bücher.localhost"])
        let t = build([c])
        #expect(t.notes["a"] == [.nameDropped("bücher.localhost"), .nameDropped("other.example.com")])
    }

    @Test func aPortOnIPv6OnlyKeepsItsFlag() {
        let t = build([standalone("a", name: "w", ports: [P(containerPort: 80, hostPort: 8000, ipv6Only: true)])])
        #expect(t.routes["w"]?.ipv6Only == true)
        #expect(build([standalone("b", name: "x")]).routes["x"]?.ipv6Only == false)
    }

    @Test func otherPublishedPortsCountForTheConflictSet() {
        let t = DomainRoutes.build(
            [standalone("a", name: "w")], suffixes: ["localhost"], profile: "p", vmRunning: true, otherPublished: [80])
        #expect(t.publishedHostPorts == [80, 8000])
    }

    @Test func aLongReplicaNameKeepsItsNumber() {
        let service = String(repeating: "s", count: 63)
        let list = (1...2).map { n in compose("c\(n)", service: service, number: n, created: Int64(n)) }
        let t = build(list)
        let names = list.compactMap { t.primaryName($0.id) }
        #expect(names.count == 2)
        for name in names {
            let label = String(name.split(separator: ".")[0])
            #expect(label.count <= 63)
        }
        #expect(names[0].hasSuffix("-1.shop"))
        #expect(names[1].hasSuffix("-2.shop"))
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

    // MARK: Notes and ports

    @Test func aContainerWithNoNameGetsNoPortNotes() {
        let t = build([standalone("a", name: "db", labelPort: 5432, labelPortInvalid: "x", domains: .off)])
        #expect(t.notes["a"] == nil)
        #expect(t.names["a"] == nil)
    }

    @Test func aNoteAppearsOncePerContainer() {
        let entry = C.Entry(name: "other.localhost", containerPort: 6379)
        let t = build([
            standalone("a", name: "app", domains: .names([entry, entry]), droppedEntries: ["x.example", "x.example"])
        ])
        #expect(t.notes["a"] == [.nameDropped("x.example"), .labelPortNotWeb(6379)])
    }

    @Test func thePreferredPortLoopSkipsAContainerPortPublishedAtADatabaseHostPort() {
        let t = build([
            standalone(
                "a", name: "app", ports: [P(containerPort: 80, hostPort: 5432), P(containerPort: 9000, hostPort: 9001)])
        ])
        #expect(t.routes["app"]?.hostPort == 9001)
        let only = build([standalone("b", name: "web", ports: [P(containerPort: 80, hostPort: 5432)])])
        #expect(only.routes["web"] == nil)
    }

    @Test func aPortOnTheIPv6WildcardOnlyGivesAnIPv6OnlyRoute() {
        let t = build([standalone("a", name: "app", ports: [P(containerPort: 80, hostPort: 8000, ipv6Only: true)])])
        #expect(t.routes["app"]?.ipv6Only == true)
    }

    @Test func aNameThatLosesNonASCIICharactersGivesANote() {
        let t = build([standalone("a", name: "Bücher-app")])
        #expect(t.routes["bcher-app"]?.containerID == "a")
        #expect(t.notes["a"] == [.nameNotASCII("Bücher-app")])
    }

    @Test func aComposeNameThatLosesNonASCIICharactersGivesANote() {
        let t = build([compose("a", project: "shöp")])
        #expect(t.notes["a"] == [.nameNotASCII("shöp")])
    }

    @Test func aNameWithNoASCIICharacterGivesAnEmptyNameNote() {
        let t = build([standalone("a", name: "日本語")])
        #expect(t.routes.isEmpty)
        #expect(t.notes["a"] == [.nameEmpty])
    }

    // MARK: Remembered names

    @Test func theNamesStayWhileTheVMStopsForTheSameProfileAndSuffixes() {
        let list = [standalone("a", name: "shop")]
        let running = DomainRoutes.build(list, suffixes: ["localhost"], profile: "p", vmRunning: true)
        #expect(running.rememberedNames == ["shop"])
        let stopped = DomainRoutes.build(
            [], suffixes: ["localhost"], profile: "p", vmRunning: false, previous: running)
        #expect(stopped.rememberedNames == ["shop"] && stopped.routes.isEmpty)
        // They survive a second rebuild of the stopped VM.
        let again = DomainRoutes.build([], suffixes: ["localhost"], profile: "p", vmRunning: false, previous: stopped)
        #expect(again.rememberedNames == ["shop"])
        #expect(stopped.routeHost(for: "shop.localhost") == "shop.localhost")
        #expect(stopped.routeHost(for: "x.shop.localhost") == "shop.localhost")
        #expect(stopped.routeHost(for: "other.localhost") == nil)
        #expect(stopped.hasRoute(for: "api.shop.localhost"))
    }

    @Test func theNamesGoWhenTheProfileTheSuffixesOrTheSwitchChange() {
        let running = DomainRoutes.build(
            [standalone("a", name: "shop")], suffixes: ["localhost"], profile: "p", vmRunning: true)
        let otherProfile = DomainRoutes.build(
            [], suffixes: ["localhost"], profile: "q", vmRunning: false, previous: running)
        #expect(otherProfile.rememberedNames.isEmpty)
        let otherSuffixes = DomainRoutes.build(
            [], suffixes: ["localhost", "colima.internal"], profile: "p", vmRunning: false, previous: running)
        #expect(otherSuffixes.rememberedNames.isEmpty)
        let off = DomainRoutes.build(
            [], suffixes: ["localhost"], profile: "p", vmRunning: false, previous: running, remember: false)
        #expect(off.rememberedNames.isEmpty && off.routeHost(for: "shop.localhost") == nil)
        #expect(DomainRoutes.empty.rememberedNames.isEmpty)
    }

    @Test func aRunningVMUsesItsRoutesAndNotTheMemory() {
        let running = DomainRoutes.build(
            [standalone("a", name: "shop")], suffixes: ["localhost"], profile: "p", vmRunning: true)
        let gone = DomainRoutes.build(
            [], suffixes: ["localhost"], profile: "p", vmRunning: true, previous: running)
        #expect(gone.rememberedNames.isEmpty && gone.routeHost(for: "shop.localhost") == nil)
        #expect(running.routeHost(for: "SHOP.localhost.") == "shop.localhost")
        #expect(running.routeHost(for: "localhost") == nil)
    }

    @Test func theRememberedNamesHaveACap() {
        let list = (0..<300).map {
            standalone("c\($0)", name: "n\($0)", ports: [P(containerPort: 80, hostPort: 20000 + $0)])
        }
        let running = DomainRoutes.build(list, suffixes: ["localhost"], profile: "p", vmRunning: true)
        #expect(running.routes.count == 300)
        #expect(running.rememberedNames.count == DomainRoutes.rememberedCap)
    }

    @Test func twoSuffixesResolveTheSameRoute() {
        let t = build([compose("a")], suffixes: ["localhost", "colima.internal"])
        for host in ["web.shop.localhost", "web.shop.colima.internal", "api.web.shop.colima.internal"] {
            if case .route(let route) = t.resolve(host: host) {
                #expect(route.containerID == "a")
            } else {
                Issue.record("no route for \(host)")
            }
        }
        #expect(t.resolve(host: "web.shop.example.com") == .foreign)
        #expect(t.resolve(host: "colima.internal") == .unknown(relative: ""))
    }

    @Test func aLabelNameUnderTheCustomSuffixBecomesRelative() {
        let named = compose("a", domains: .names([.init(name: "admin.shop.colima.internal", containerPort: nil)]))
        let t = build([named], suffixes: ["localhost", "colima.internal"])
        #expect(t.routes["admin.shop"]?.containerID == "a")
    }
}
