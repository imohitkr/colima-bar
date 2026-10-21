import Foundation
import Testing

@testable import ColimaBar

/// The ports that stopped containers still claim, and the hint to restart a
/// container whose port the proxy held when it started.
@MainActor @Suite struct ColimaModelDomainClaimsTests {
    private func list(_ items: String...) throws -> [APIContainer] {
        try JSONDecoder().decode([APIContainer].self, from: Data(("[" + items.joined(separator: ",") + "]").utf8))
    }

    private func web(_ id: String, host hostPort: Int) -> String {
        """
        {"Id":"\(id)","Names":["/\(id)"],"Image":"x","State":"running","Status":"Up","Created":1,
         "Ports":[{"IP":"0.0.0.0","PublicPort":\(hostPort),"PrivatePort":80,"Type":"tcp"}]}
        """
    }

    /// The Docker list gives no ports for a stopped container.
    private func stopped(_ id: String) -> String {
        """
        {"Id":"\(id)","Names":["/\(id)"],"Image":"x","State":"exited","Status":"Exited (0) 1 second ago","Created":1}
        """
    }

    private func rig(gap: TimeInterval = 0) -> (model: ColimaModel, proxy: FakeDomainProxy) {
        let fake = FakeDomainProxy()
        let model = ColimaModel(
            profile: "domains-claims-\(UUID().uuidString.prefix(6))", domainProxy: fake, domainsEnabled: true)
        model.domainTimings = DomainTimings(launchRetry: 0.01, failureRetry: 0.05, rebindGap: gap)
        model.setState(.running)
        return (model, fake)
    }

    /// A proxy on 80 that a container then made move to 8080.
    private func movedToFallback(_ model: ColimaModel) async throws {
        model.startDomainProxy()
        #expect(await waitUntil { model.domainStatus.httpPort == 80 && model.domainStatus.phase == .running })
        model.updateDomainRoutes(try list(web("web", host: 80)))
        #expect(await waitUntil { model.domainStatus.httpPort == 8080 && model.domainStatus.phase == .running })
    }

    @Test func aStoppedContainerKeepsItsClaim() throws {
        let (model, _) = rig()
        model.updateDomainRoutes(try list(web("web", host: 80)))
        model.updateDomainRoutes(try list(stopped("web")))
        #expect(model.domainClaims.ports == [80])
        #expect(model.domainRoutes.publishedHostPorts.isEmpty)
    }

    @Test func aDestroyedContainerReleasesItsClaim() throws {
        let (model, _) = rig()
        model.updateDomainRoutes(try list(web("web", host: 80), web("db", host: 5432)))
        model.updateDomainRoutes(try list(stopped("web"), web("db", host: 5432)))
        model.updateDomainRoutes(try list(web("db", host: 5432)))
        #expect(model.domainClaims.ports == [5432])
    }

    @Test func aStoppedVMKeepsTheClaimsAndAProfileSwitchClearsThem() throws {
        let (model, _) = rig()
        model.updateDomainRoutes(try list(web("web", host: 80)))
        model.clearVMData(because: .vmStopped)
        #expect(model.domainClaims.ports == [80])
        model.clearVMData(because: .profileChanged)
        #expect(model.domainClaims.ports.isEmpty)
    }

    @Test func aStoppedContainerKeepsTheProxyOffItsPort() async throws {
        let (model, proxy) = rig()
        try await movedToFallback(model)
        model.updateDomainRoutes(try list(stopped("web")))
        model.rebuildDomainRoutes()
        model.domainsHeartbeat()
        model.domainsAfterWake()
        try await Task.sleep(for: .milliseconds(80))
        #expect(model.domainStatus.httpPort == 8080)
        #expect(proxy.starts.count == 2)
        model.stopDomainProxy()
    }

    @Test func theProxyGoesBackToPort80WhenNoContainerClaimsIt() async throws {
        let (model, _) = rig()
        try await movedToFallback(model)
        model.updateDomainRoutes(try list(stopped("web")))
        model.updateDomainRoutes([])
        #expect(await waitUntil { model.domainStatus.httpPort == 80 && model.domainStatus.phase == .running })
        model.stopDomainProxy()
    }

    @Test func aStartSkipsAPortThatAStoppedContainerClaims() async throws {
        let (model, proxy) = rig()
        model.updateDomainRoutes(try list(web("web", host: 80)))
        model.updateDomainRoutes(try list(stopped("web")))
        model.startDomainProxy()
        #expect(await waitUntil { model.domainStatus.httpPort == 8080 && model.domainStatus.phase == .running })
        #expect(proxy.starts == [[8080]])
        #expect(model.domainRestartHints.isEmpty)
        model.stopDomainProxy()
    }

    @Test func aConflictRebindShowsTheRestartHint() async throws {
        let (model, _) = rig()
        try await movedToFallback(model)
        #expect(model.domainRestartHints.map(\.id) == ["web"])
        #expect(
            model.domainRestartHints.first?.text == "web uses port 80. Restart web so its port 80 works on the Mac.")
        #expect(model.alerts.count == 1)
        #expect(model.alerts.first?.containerID == "web")
        // The same list again does not repeat the alert.
        model.updateDomainRoutes(try list(web("web", host: 80)))
        #expect(model.alerts.count == 1)
        model.stopDomainProxy()
    }

    @Test func theHintEndsWhenTheContainerRestarts() async throws {
        let (model, _) = rig()
        try await movedToFallback(model)
        model.updateDomainRoutes(try list(stopped("web")))
        #expect(model.domainRestartHints.isEmpty)
        model.updateDomainRoutes(try list(web("web", host: 80)))
        #expect(model.domainRestartHints.isEmpty)
        model.stopDomainProxy()
    }

    @Test func theHintEndsWhenTheContainerIsRemoved() async throws {
        let (model, _) = rig()
        try await movedToFallback(model)
        model.updateDomainRoutes([])
        #expect(model.domainRestartHints.isEmpty)
        model.stopDomainProxy()
    }

    @Test func aLaunchTimeSkipShowsNoHint() async throws {
        let (model, _) = rig()
        model.updateDomainRoutes(try list(web("web", host: 80)))
        model.startDomainProxy()
        #expect(await waitUntil { model.domainStatus.httpPort == 8080 && model.domainStatus.phase == .running })
        #expect(model.domainRestartHints.isEmpty)
        #expect(model.alerts.isEmpty)
        model.stopDomainProxy()
    }
}
