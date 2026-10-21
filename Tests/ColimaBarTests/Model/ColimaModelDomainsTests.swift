import Foundation
import Testing

@testable import ColimaBar

/// The model glue of container domains. The models here are debug runs or
/// are never started, so no test starts a proxy.
@MainActor @Suite struct ColimaModelDomainsTests {
    private func list(_ json: String) throws -> [APIContainer] {
        try JSONDecoder().decode([APIContainer].self, from: Data(json.utf8))
    }

    private let shop = """
        [{"Id":"a1","Names":["/shop-web-1"],"Image":"x","State":"running","Status":"Up","Created":1,
          "Ports":[{"IP":"0.0.0.0","PublicPort":8000,"PrivatePort":80,"Type":"tcp"}],
          "Labels":{"com.docker.compose.project":"shop","com.docker.compose.service":"web",
                    "com.docker.compose.container-number":"1","dev.colimabar.domains":"admin.shop.localhost"}},
         {"Id":"b2","Names":["/db"],"Image":"x","State":"running","Status":"Up","Created":2,
          "Ports":[{"IP":"0.0.0.0","PublicPort":5432,"PrivatePort":5432,"Type":"tcp"}]}]
        """

    /// Restores the saved setting after a test that writes it.
    private func keepingDomainsSetting(_ body: () throws -> Void) rethrows {
        let saved = Defaults.bool(.domains)
        defer { if let saved { Defaults.set(saved, .domains) } else { Defaults.remove(.domains) } }
        try body()
    }

    @Test func aDebugRunStartsNoProxyWhenTheSettingTurnsOn() {
        keepingDomainsSetting {
            let model = ColimaModel(profile: "domains-test-a", readOnly: true)
            model.domainsEnabled = false
            model.domainsEnabled = true
            #expect(model.domainStatus.phase == .debugRun)
            #expect(model.domainProxy.port == nil)
            #expect(model.domainStatus.caption(routeCount: 0) == Help.domainsDebug)
            model.domainsEnabled = false
        }
    }

    @Test func aDebugRunComputesNoRoutesUnlessItShowsThem() throws {
        try keepingDomainsSetting {
            let model = ColimaModel(profile: "domains-test-b", readOnly: true)
            model.domainsEnabled = false
            model.setState(.running)
            model.updateDomainRoutes(try list(shop))
            #expect(model.domainRoutes == .empty)
            model.domainsShownInDebug = true
            model.rebuildDomainRoutes()
            #expect(model.domainRoutes.routes.keys.sorted() == ["admin.shop", "web.shop"])
            #expect(model.domainProxy.routes == .empty)
        }
    }

    @Test func theRoutesFollowTheVMState() throws {
        try keepingDomainsSetting {
            let model = ColimaModel(profile: "domains-test-c", readOnly: true)
            model.domainsShownInDebug = true
            model.setState(.running)
            model.updateDomainRoutes(try list(shop))
            #expect(model.domainRoutes.vmRunning)
            model.setState(.stopped)
            #expect(!model.domainRoutes.vmRunning)
            #expect(model.domainRoutes.resolve(host: "web.shop.localhost") == .vmStopped)
            #expect(model.domainRoutes.profile == "domains-test-c")
        }
    }

    @Test func clearingTheVMDataEmptiesTheRoutes() throws {
        try keepingDomainsSetting {
            let model = ColimaModel(profile: "domains-test-d", readOnly: true)
            model.domainsShownInDebug = true
            model.setState(.running)
            model.updateDomainRoutes(try list(shop))
            #expect(model.domainRoutes.count == 1)
            model.clearVMData(because: .vmStopped)
            #expect(model.domainRoutes.routes.isEmpty)
            #expect(model.domainCandidates.isEmpty)
        }
    }

    @Test func aRefreshOfTheContainerListGivesTheRoutes() async throws {
        let body = Data(shop.utf8)
        let daemon = FakeDaemon(path: TestSocketPath.unique()) { line in
            line.hasPrefix("GET /containers/json") ? (200, body) : (200, Data("[]".utf8))
        }
        try daemon.start()
        defer { daemon.stop() }
        let saved = Defaults.bool(.domains)
        defer { if let saved { Defaults.set(saved, .domains) } else { Defaults.remove(.domains) } }
        let model = ColimaModel(
            profile: "domains-test-e", readOnly: true, dockerAPI: DockerAPI(socketPath: daemon.path))
        model.domainsShownInDebug = true
        model.setState(.running)
        #expect(await model.refreshContainers())
        #expect(model.domainRoutes.routes["web.shop"]?.hostPort == 8000)
        #expect(model.domainRoutes.routes["admin.shop"]?.hostPort == 8000)
        #expect(model.domainRoutes.primaryName("a1") == "web.shop")
        #expect(model.domainRoutes.projects["shop"] == ["admin.shop", "web.shop"])
        #expect(model.domainURL("web.shop")?.absoluteString == "http://web.shop.localhost/")
    }

    @Test func linksCarryTheFallbackPort() {
        let model = ColimaModel(profile: "domains-test-f", readOnly: true)
        model.setDomainStatus(DomainStatus(phase: .running, httpPort: 8080))
        #expect(model.domainURL("web.shop")?.absoluteString == "http://web.shop.localhost:8080/")
    }

    @Test func aPublishedProxyPortIsAConflictOnlyWhileTheProxyRuns() {
        let running = DomainStatus(phase: .running, httpPort: 8080)
        #expect(ColimaModel.domainConflictPort(status: running, published: [8080, 3000]))
        #expect(!ColimaModel.domainConflictPort(status: running, published: [80, 3000]))
        #expect(!ColimaModel.domainConflictPort(status: running, published: []))
        for phase in [DomainStatus.Phase.off, .debugRun, .starting, .failed] {
            #expect(
                !ColimaModel.domainConflictPort(status: DomainStatus(phase: phase, httpPort: 8080), published: [8080]))
        }
        #expect(!ColimaModel.domainConflictPort(status: DomainStatus(phase: .running), published: [80]))
    }

    @Test func theDiagnosticsLineHoldsCountsAndPortsOnly() throws {
        try keepingDomainsSetting {
            let model = ColimaModel(profile: "domains-test-g", readOnly: true)
            model.domainsShownInDebug = true
            model.setState(.running)
            model.updateDomainRoutes(try list(shop))
            model.setDomainStatus(DomainStatus(phase: .running, httpPort: 8080))
            #expect(model.domainStatusText == "listening on port 8080, 1 containers with a name")
            #expect(!model.domainStatusText.contains("shop"))
        }
    }

    @Test func theSettingIsInTheSnapshotAndApplies() {
        keepingDomainsSetting {
            let model = ColimaModel(profile: "domains-test-h", readOnly: true)
            model.domainsEnabled = false
            #expect(model.settingsSnapshot[.domains] == .bool(false))
            let note = model.apply(.init(setting: .domains, from: .bool(false), to: .bool(true)))
            #expect(note == nil)
            #expect(model.domainsEnabled)
            #expect(model.settingsSnapshot[.domains] == .bool(true))
            #expect(Defaults.bool(.domains) == true)
            model.domainsEnabled = false
        }
    }
}
