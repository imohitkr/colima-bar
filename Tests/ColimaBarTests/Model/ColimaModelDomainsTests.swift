import Foundation
import Testing

@testable import ColimaBar

/// The model glue of container domains. A model here is a debug run, or it
/// has a `FakeDomainProxy`, so no test binds a real port.
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

    /// A model that is not a debug run, with a fake proxy and short times.
    private func rig(
        enabled: Bool = true, gap: TimeInterval = 0, launchRetry: TimeInterval = 0.01, failureRetry: TimeInterval = 0.05
    ) -> (model: ColimaModel, proxy: FakeDomainProxy) {
        let fake = FakeDomainProxy()
        let model = ColimaModel(
            profile: "domains-life-\(UUID().uuidString.prefix(6))", domainProxy: fake, domainsEnabled: enabled)
        model.domainTimings = DomainTimings(launchRetry: launchRetry, failureRetry: failureRetry, rebindGap: gap)
        model.setState(.running)
        return (model, fake)
    }

    /// A running container that publishes `hostPort` for its port 80.
    private func web(_ id: String, host hostPort: Int) -> String {
        """
        {"Id":"\(id)","Names":["/\(id)"],"Image":"x","State":"running","Status":"Up","Created":1,
         "Ports":[{"IP":"0.0.0.0","PublicPort":\(hostPort),"PrivatePort":80,"Type":"tcp"}]}
        """
    }

    private func containers(_ items: String...) throws -> [APIContainer] {
        try list("[" + items.joined(separator: ",") + "]")
    }

    @Test func aDebugRunStartsNoProxyAndWritesNoSetting() {
        let store = TestProcess.emptyStore()
        let fake = FakeDomainProxy()
        let model = ColimaModel(profile: "domains-test-a", readOnly: true, domainProxy: fake, domainsStore: store)
        model.domainsEnabled = true
        #expect(model.domainStatus.phase == .debugRun)
        #expect(fake.starts.isEmpty)
        #expect(model.domainProxy.port == nil)
        #expect(model.domainStatus.caption(routeCount: 0) == Help.domainsDebug)
        #expect(store.object(forKey: Defaults.Key.domains.rawValue) == nil)
    }

    @Test func aSavedSettingDoesNotShowNamesInADebugRun() throws {
        let model = ColimaModel(profile: "domains-test-a2", readOnly: true, domainsEnabled: true)
        #expect(model.domainsEnabled)
        #expect(!model.domainsActive)
        model.setState(.running)
        model.updateDomainRoutes(try list(shop))
        #expect(model.domainRoutes == .empty)
        model.domainsShownInDebug = true
        #expect(model.domainsActive)
    }

    @Test func aDebugRunComputesNoRoutesUnlessItShowsThem() throws {
        let model = ColimaModel(profile: "domains-test-b", readOnly: true)
        model.setState(.running)
        model.updateDomainRoutes(try list(shop))
        #expect(model.domainRoutes == .empty)
        model.domainsShownInDebug = true
        model.rebuildDomainRoutes()
        #expect(model.domainRoutes.routes.keys.sorted() == ["admin.shop", "web.shop"])
        #expect(model.domainProxy.routes == .empty)
    }

    @Test func theRoutesFollowTheVMState() throws {
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

    @Test func clearingTheVMDataEmptiesTheRoutes() throws {
        let model = ColimaModel(profile: "domains-test-d", readOnly: true)
        model.domainsShownInDebug = true
        model.setState(.running)
        model.updateDomainRoutes(try list(shop))
        #expect(model.domainRoutes.count == 1)
        model.clearVMData(because: .vmStopped)
        #expect(model.domainRoutes.routes.isEmpty)
        #expect(model.domainCandidates.isEmpty)
    }

    @Test func aRefreshOfTheContainerListGivesTheRoutes() async throws {
        let body = Data(shop.utf8)
        let daemon = FakeDaemon(path: TestSocketPath.unique()) { line in
            line.hasPrefix("GET /containers/json") ? (200, body) : (200, Data("[]".utf8))
        }
        try daemon.start()
        defer { daemon.stop() }
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

    @Test func linksCarryTheFallbackPortAndExistOnlyWhileTheProxyRuns() {
        let (model, _) = rig()
        #expect(model.domainURL("web.shop") == nil)
        model.setDomainStatus(DomainStatus(phase: .running, httpPort: 8080))
        #expect(model.domainURL("web.shop")?.absoluteString == "http://web.shop.localhost:8080/")
        model.setDomainStatus(DomainStatus(phase: .running, httpPort: 80))
        #expect(model.domainURL("web.shop")?.absoluteString == "http://web.shop.localhost/")
        for phase in [DomainStatus.Phase.off, .starting, .failed] {
            model.setDomainStatus(DomainStatus(phase: phase))
            #expect(model.domainURL("web.shop") == nil)
        }
    }

    @Test func aDebugRunShowsLinksOnPort80() {
        let model = ColimaModel(profile: "domains-test-f", readOnly: true)
        model.setDomainStatus(DomainStatus(phase: .debugRun))
        #expect(model.domainURL("web.shop")?.absoluteString == "http://web.shop.localhost/")
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
        let model = ColimaModel(profile: "domains-test-g", readOnly: true)
        model.domainsShownInDebug = true
        model.setState(.running)
        model.updateDomainRoutes(try list(shop))
        model.setDomainStatus(DomainStatus(phase: .running, httpPort: 8080))
        #expect(model.domainStatusText == "listening on port 8080, 1 containers with a name")
        #expect(!model.domainStatusText.contains("shop"))
    }

    @Test func theSavedSettingStartsTheModelAndAModelInATestProcessReadsNoRealOne() {
        let store = TestProcess.emptyStore()
        store.set(true, forKey: Defaults.Key.domains.rawValue)
        #expect(
            ColimaModel(profile: "domains-test-i", domainProxy: FakeDomainProxy(), domainsStore: store).domainsEnabled)
        // No argument: the test process gets an inert proxy and an empty store.
        let plain = ColimaModel(profile: "domains-test-j")
        #expect(!plain.domainsEnabled)
        #expect(plain.domainProxy is InertDomainProxy)
    }

    @Test func theSettingIsInTheSnapshotAndApplies() {
        let store = TestProcess.emptyStore()
        let key = Defaults.Key.domains.rawValue
        store.set(false, forKey: key)
        let model = ColimaModel(profile: "domains-test-h", domainProxy: FakeDomainProxy(), domainsStore: store)
        #expect(model.settingsSnapshot[.domains] == .bool(false))
        let note = model.apply(.init(setting: .domains, from: .bool(false), to: .bool(true)))
        #expect(note == nil)
        #expect(model.domainsEnabled)
        #expect(model.settingsSnapshot[.domains] == .bool(true))
        #expect(store.object(forKey: key) as? Bool == true)
        model.stopDomainProxy()
        model.domainsEnabled = false
    }

    // MARK: Proxy lifecycle

    @Test func theProxyStartsOnPort80() async throws {
        let (model, proxy) = rig()
        model.startDomainProxy()
        #expect(await waitUntil { model.domainStatus.phase == .running })
        #expect(model.domainStatus.httpPort == 80)
        #expect(proxy.starts == [[80]])
        #expect(model.domainURL("web.shop")?.absoluteString == "http://web.shop.localhost/")
        model.stopDomainProxy()
        #expect(model.domainStatus.phase == .off)
        #expect(proxy.stops == 1)
        #expect(model.domainURL("web.shop") == nil)
    }

    @Test func aBusyPort80MakesTheProxyTake8080() async throws {
        let (model, proxy) = rig()
        proxy.busyPorts = [80]
        model.startDomainProxy()
        #expect(await waitUntil { model.domainStatus.phase == .running })
        #expect(model.domainStatus.httpPort == 8080)
        #expect(proxy.starts == [[80], [8080]])
        model.stopDomainProxy()
    }

    @Test func theLaunchTriesPort80TwiceBefore8080() async throws {
        let (model, proxy) = rig()
        proxy.busyPorts = [80]
        model.startDomainProxy()
        #expect(await waitUntil { model.domainStatus.phase == .running })
        model.stopDomainProxy()
        proxy.busyPorts = [80]
        model.startDomainProxy(retryFirst: true)
        #expect(await waitUntil { model.domainStatus.phase == .running })
        #expect(Array(proxy.starts.suffix(3)) == [[80], [80], [8080]])
    }

    @Test func thePortThatFreesDuringTheLaunchWaitIsTaken() async throws {
        let (model, proxy) = rig()
        model.startDomainProxy()
        #expect(await waitUntil { model.domainStatus.phase == .running })
        model.stopDomainProxy()
        proxy.busyPorts = [80]
        // The second try of port 80 finds it free.
        proxy.onStart { _ in if proxy.starts.count == 2 { proxy.busyPorts = [] } }
        model.startDomainProxy(retryFirst: true)
        #expect(await waitUntil { model.domainStatus.phase == .running })
        #expect(model.domainStatus.httpPort == 80)
    }

    @Test func aFailedProxyTriesAgainWhenThePublishedPortsChange() async throws {
        // The retry wait is much longer than the checks below.
        let (model, proxy) = rig(failureRetry: 60)
        proxy.busyPorts = [80, 8080]
        model.startDomainProxy()
        #expect(await waitUntil { model.domainStatus.phase == .failed })
        let tries = proxy.starts.count
        // A new published port gives one new try. The ports are still busy, so it fails again.
        model.updateDomainRoutes(try containers(web("a", host: 5000)))
        #expect(await waitUntil { proxy.starts.count > tries && model.domainStatus.phase == .failed })
        let after = proxy.starts.count
        // The same ports: no new try.
        model.rebuildDomainRoutes()
        try await Task.sleep(for: .milliseconds(100))
        #expect(model.domainStatus.phase == .failed)
        #expect(proxy.starts.count == after)
        proxy.busyPorts = []
        model.updateDomainRoutes(try containers(web("a", host: 5000), web("b", host: 5001)))
        #expect(await waitUntil { model.domainStatus.phase == .running })
        #expect(proxy.starts.count > after)
        model.stopDomainProxy()
    }

    @Test func aContainerThatPublishesPort80MakesTheProxyMove() async throws {
        let (model, proxy) = rig()
        model.startDomainProxy()
        #expect(await waitUntil { model.domainStatus.httpPort == 80 })
        model.updateDomainRoutes(try containers(web("a", host: 80)))
        #expect(await waitUntil { model.domainStatus.httpPort == 8080 && model.domainStatus.phase == .running })
        #expect(proxy.starts.last == [8080])
        model.stopDomainProxy()
    }

    @Test func aPortPublishedWhileTheProxyStartsIsFoundAfterTheStart() async throws {
        let (model, proxy) = rig()
        let list = try containers(web("a", host: 80))
        proxy.onStart { _ in
            // A container publishes port 80 while the first start runs.
            if proxy.starts.count == 1 { await MainActor.run { model.updateDomainRoutes(list) } }
        }
        model.startDomainProxy()
        #expect(await waitUntil { model.domainStatus.httpPort == 8080 && model.domainStatus.phase == .running })
        #expect(proxy.starts == [[80], [8080]])
        model.stopDomainProxy()
    }

    @Test func aRebindInsideTheGapRunsWhenTheGapEnds() async throws {
        let (model, proxy) = rig(gap: 0.4)
        model.startDomainProxy()
        #expect(await waitUntil { model.domainStatus.httpPort == 80 })
        model.updateDomainRoutes(try containers(web("a", host: 80)))
        #expect(await waitUntil { model.domainStatus.httpPort == 8080 && model.domainStatus.phase == .running })
        let tries = proxy.starts.count
        // Now 8080 is published and 80 is free: a conflict inside the gap.
        model.updateDomainRoutes(try containers(web("b", host: 8080)))
        #expect(proxy.starts.count == tries)
        #expect(await waitUntil { model.domainStatus.httpPort == 80 && model.domainStatus.phase == .running })
        #expect(proxy.starts.count == tries + 1)
        model.stopDomainProxy()
    }

    @Test func aProxyOnTheFallbackPortGoesBackToPort80() async throws {
        let (model, proxy) = rig()
        proxy.busyPorts = [80]
        model.startDomainProxy()
        #expect(await waitUntil { model.domainStatus.httpPort == 8080 && model.domainStatus.phase == .running })
        // A route rebuild with port 80 still busy changes nothing.
        model.rebuildDomainRoutes()
        #expect(await waitUntil { !model.domainMoveBackProbing })
        #expect(proxy.starts.count == 2)
        #expect(model.domainStatus.httpPort == 8080)
        proxy.busyPorts = []
        model.rebuildDomainRoutes()
        #expect(await waitUntil { model.domainStatus.httpPort == 80 && model.domainStatus.phase == .running })
        model.stopDomainProxy()
    }

    @Test func aContainerThatPublishesPort80KeepsTheProxyOnTheFallbackPort() async throws {
        let (model, proxy) = rig()
        proxy.busyPorts = [80]
        model.startDomainProxy()
        #expect(await waitUntil { model.domainStatus.httpPort == 8080 && model.domainStatus.phase == .running })
        proxy.busyPorts = []
        model.updateDomainRoutes(try containers(web("a", host: 80)))
        try await Task.sleep(for: .milliseconds(100))
        #expect(model.domainStatus.httpPort == 8080)
        #expect(proxy.starts.count == 2)
        model.stopDomainProxy()
    }

    @Test func theMoveBackWaitsForTheRebindGap() async throws {
        let (model, proxy) = rig(gap: 0.4)
        proxy.busyPorts = [80]
        model.startDomainProxy()
        #expect(await waitUntil { model.domainStatus.httpPort == 8080 && model.domainStatus.phase == .running })
        // The proxy moved a moment ago because a container took port 80.
        model.updateDomainRoutes(try containers(web("a", host: 80)))
        #expect(await waitUntil { model.domainStatus.phase == .running })
        model.updateDomainRoutes([])
        proxy.busyPorts = []
        let tries = proxy.starts.count
        model.rebuildDomainRoutes()
        #expect(await waitUntil { model.domainStatus.httpPort == 80 && model.domainStatus.phase == .running })
        #expect(proxy.starts.count == tries + 1)
        model.stopDomainProxy()
    }

    @Test func aWakeStartsAProxyThatIsGoneAndMovesBackToPort80() async throws {
        let (model, proxy) = rig()
        proxy.busyPorts = [80]
        model.startDomainProxy()
        #expect(await waitUntil { model.domainStatus.httpPort == 8080 && model.domainStatus.phase == .running })
        proxy.busyPorts = []
        model.domainsAfterWake()
        #expect(await waitUntil { model.domainStatus.httpPort == 80 && model.domainStatus.phase == .running })
        proxy.stop()
        let tries = proxy.starts.count
        model.domainsAfterWake()
        #expect(await waitUntil { proxy.starts.count > tries && model.domainStatus.phase == .running })
        model.stopDomainProxy()
    }

    @Test func aWakeDoesNothingWhileTheSettingIsOff() async throws {
        let (model, proxy) = rig(enabled: false)
        model.domainsAfterWake()
        try await Task.sleep(for: .milliseconds(50))
        #expect(proxy.starts.isEmpty)
        #expect(model.domainStatus.phase == .off)
    }

    @Test func aListenerThatFailsStartsAgainAfterAShortWait() async throws {
        let (model, proxy) = rig()
        model.startDomainProxy()
        #expect(await waitUntil { model.domainStatus.phase == .running })
        proxy.failListener()
        #expect(await waitUntil { model.domainStatus.phase == .failed })
        #expect(model.domainStatus.caption(routeCount: 0) == "The proxy stopped. ColimaBar tries again soon.")
        #expect(await waitUntil { model.domainStatus.phase == .running })
        #expect(proxy.starts.count == 2)
        model.stopDomainProxy()
    }

    @Test func aStopDuringAStartLeavesTheProxyOff() async throws {
        let (model, proxy) = rig()
        let gate = DispatchSemaphore(value: 0)
        proxy.onStart { _ in await onOwnThread { gate.wait() } }
        model.startDomainProxy()
        #expect(await waitUntil { proxy.starts.count == 1 })
        model.stopDomainProxy()
        gate.signal()
        try await Task.sleep(for: .milliseconds(100))
        #expect(model.domainStatus.phase == .off)
    }

    @Test func aNewStartMakesAnOlderStartStale() async throws {
        let (model, proxy) = rig()
        let gate = DispatchSemaphore(value: 0)
        proxy.onStart { _ in
            if proxy.starts.count == 1 { await onOwnThread { gate.wait() } }
        }
        model.startDomainProxy()
        #expect(await waitUntil { proxy.starts.count == 1 })
        model.startDomainProxy()
        #expect(await waitUntil { model.domainStatus.phase == .running })
        proxy.busyPorts = [80]
        gate.signal()
        try await Task.sleep(for: .milliseconds(100))
        // The first start returned late. Its result must not replace the second one.
        #expect(model.domainStatus.phase == .running)
        #expect(model.domainStatus.httpPort == 80)
        model.stopDomainProxy()
    }

    @Test func theRetryWaitsGrowAndStayAtFiveMinutes() {
        let timings = DomainTimings()
        #expect((0...5).map { timings.failureDelay(attempt: $0) } == [5, 15, 60, 300, 300, 300])
    }

    @Test func aFailedProxyKeepsTryingUntilAPortIsFree() async throws {
        let (model, proxy) = rig(failureRetry: 0.01)
        proxy.busyPorts = [80, 8080]
        model.startDomainProxy()
        // Each failed try plans the next one. A try that runs shows `.starting`
        // for a moment, so the check waits for six tries and the failed phase together.
        #expect(await waitUntil { proxy.starts.count >= 6 && model.domainStatus.phase == .failed })
        proxy.busyPorts = []
        #expect(await waitUntil { model.domainStatus.phase == .running })
        let tries = proxy.starts.count
        try await Task.sleep(for: .milliseconds(100))
        #expect(proxy.starts.count == tries)
        model.stopDomainProxy()
    }

    @Test func aListenerThatFailsAgainAfterTheRetryIsTriedAgain() async throws {
        let (model, proxy) = rig(failureRetry: 0.01)
        model.startDomainProxy()
        #expect(await waitUntil { model.domainStatus.phase == .running })
        proxy.failListener()
        proxy.busyPorts = [80, 8080]
        #expect(await waitUntil { proxy.starts.count >= 4 && model.domainStatus.phase == .failed })
        proxy.busyPorts = []
        #expect(await waitUntil { model.domainStatus.phase == .running })
        model.stopDomainProxy()
    }

    @Test func aStaleFailureCallbackLeavesANewerStartAlone() async throws {
        let (model, proxy) = rig(failureRetry: 60)
        model.startDomainProxy()
        #expect(await waitUntil { model.domainStatus.phase == .running })
        let stale = try #require(proxy.onListenerFailure)
        model.startDomainProxy()
        #expect(await waitUntil { model.domainStatus.phase == .running && proxy.starts.count == 2 })
        stale()
        try await Task.sleep(for: .milliseconds(100))
        #expect(model.domainStatus.phase == .running)
        #expect(proxy.starts.count == 2)
        model.stopDomainProxy()
    }

    @Test func invalidatingTheTasksStopsTheRetries() async throws {
        let (model, proxy) = rig(failureRetry: 0.3)
        proxy.busyPorts = [80, 8080]
        model.startDomainProxy()
        #expect(await waitUntil { model.domainStatus.phase == .failed })
        let tries = proxy.starts.count
        // What `shutdown()` does to the timers.
        model.invalidateDomainTasks()
        proxy.busyPorts = []
        try await Task.sleep(for: .milliseconds(700))
        #expect(proxy.starts.count == tries)
        #expect(model.domainStatus.phase == .failed)
    }

    @Test func theHeartbeatMovesAProxyBackToPort80AfterTheGap() async throws {
        let (model, proxy) = rig(gap: 0.2)
        proxy.busyPorts = [80]
        model.startDomainProxy()
        #expect(await waitUntil { model.domainStatus.httpPort == 8080 && model.domainStatus.phase == .running })
        proxy.busyPorts = []
        // The first tick may fall inside the gap. Later ticks move the proxy.
        #expect(
            await waitUntil {
                model.domainsHeartbeat()
                return model.domainStatus.httpPort == 80 && model.domainStatus.phase == .running
            })
        model.stopDomainProxy()
    }

    @Test func theHeartbeatDoesNothingOnPort80() async throws {
        let (model, proxy) = rig(gap: 0)
        model.startDomainProxy()
        #expect(await waitUntil { model.domainStatus.httpPort == 80 })
        model.domainsHeartbeat()
        try await Task.sleep(for: .milliseconds(50))
        #expect(proxy.starts.count == 1)
        model.stopDomainProxy()
    }
}
