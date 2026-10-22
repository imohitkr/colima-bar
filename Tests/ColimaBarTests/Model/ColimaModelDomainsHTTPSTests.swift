import Foundation
import Testing

@testable import ColimaBar

/// The model glue of HTTPS for container domains. The model has a fake proxy
/// and fake TLS services: no test makes a CA on disk, shows a dialog, touches
/// a keychain or a trust setting, or binds a port.
@MainActor @Suite struct ColimaModelDomainsHTTPSTests {
    private struct Rig {
        let model: ColimaModel
        let proxy: FakeDomainProxy
        let tls: FakeDomainTLS
        let store: UserDefaults
        let dialogs: Counter
        let restores: Counter
    }

    private func rig(
        https: Bool = false, ca: Bool = false, domains: Bool = true, gap: TimeInterval = 0,
        failureRetry: TimeInterval = 0.05, pending: Bool = false, removing: Bool = false,
        permitted: [String] = ["localhost"],
        trustRecheck: TimeInterval = 60, multiSANRenew: TimeInterval = 3600, dashboardOpen: Bool = false
    ) throws -> Rig {
        let proxy = FakeDomainProxy()
        let tls = FakeDomainTLS()
        if ca { tls.ca = try LocalCA.create(permitted: permitted) }
        let store = TestProcess.emptyStore()
        if pending { store.set(true, forKey: Defaults.Key.domainsHTTPSPending.rawValue) }
        if removing { store.set(true, forKey: Defaults.Key.domainsHTTPSRemoving.rawValue) }
        let model = ColimaModel(
            profile: "https-life-\(UUID().uuidString.prefix(6))", domainProxy: proxy, domainsEnabled: domains,
            domainsStore: store, httpsEnabled: https, domainTLS: tls)
        model.domainTimings = DomainTimings(
            launchRetry: 0.01, failureRetry: failureRetry, rebindGap: gap, multiSANDebounce: 0.05,
            multiSANRenew: multiSANRenew,
            trustRecheck: trustRecheck)
        model.setState(.running)
        let dialogs = Counter()
        model.dismissPopover = { dialogs.add() }
        let restores = Counter()
        model.restoreDashboard = { restores.add() }
        if dashboardOpen { model.visibleCount = 1 }
        return Rig(model: model, proxy: proxy, tls: tls, store: store, dialogs: dialogs, restores: restores)
    }

    private func web(_ id: String, host hostPort: Int) -> String {
        """
        {"Id":"\(id)","Names":["/\(id)"],"Image":"x","State":"running","Status":"Up","Created":1,
         "Ports":[{"IP":"0.0.0.0","PublicPort":\(hostPort),"PrivatePort":80,"Type":"tcp"}]}
        """
    }

    private func containers(_ items: String...) throws -> [APIContainer] {
        try JSONDecoder().decode([APIContainer].self, from: Data(("[" + items.joined(separator: ",") + "]").utf8))
    }

    private func running(_ r: Rig) async -> Bool { await waitUntil { r.model.domainStatus.https.phase == .running } }

    private func turnOn(_ r: Rig) async {
        r.model.setHTTPS(true)
        _ = await running(r)
    }

    // MARK: Safety

    @Test func aDebugRunNeverStartsHTTPS() throws {
        let tls = FakeDomainTLS()
        let proxy = FakeDomainProxy()
        let model = ColimaModel(
            profile: "https-debug", readOnly: true, domainProxy: proxy, domainsEnabled: true,
            domainsStore: TestProcess.emptyStore(), httpsEnabled: true, domainTLS: tls)
        model.setHTTPS(true)
        model.setHTTPS(false)
        model.startHTTPSAtLaunch()
        model.trustCAAgain()
        #expect(tls.events.isEmpty)
        #expect(proxy.httpsStarts.isEmpty)
        #expect(model.domainStatus.https == DomainStatus.HTTPS())
    }

    @Test func aModelInATestProcessGetsInertServices() async throws {
        let model = ColimaModel(profile: "https-inert", domainProxy: FakeDomainProxy(), domainsEnabled: true)
        #expect(model.domainTLS is InertDomainTLS)
        model.setState(.running)
        model.setHTTPS(true)
        #expect(await waitUntil { model.domainStatus.https.phase == .off && model.domainStatus.https.problem != nil })
        #expect(!model.httpsEnabled)
        #expect(model.domainTLS.loadCA() == nil)
    }

    @Test func theSwitchDoesNothingWhileDomainsAreOff() throws {
        let r = try rig(domains: false)
        r.model.setHTTPS(true)
        #expect(r.tls.events.isEmpty && !r.model.httpsEnabled)
    }

    @Test func theHTTPSSettingIsNotInTheSettingsFile() throws {
        let r = try rig(https: true)
        #expect(r.model.settingsSnapshot[.domains] != nil)
        #expect(!SettingsTransfer.Setting.allCases.map(\.rawValue).contains("domainsHTTPS"))
        #expect(!r.model.settingsSnapshot.keys.map(\.rawValue).contains("domainsHTTPS"))
    }

    @Test func theSavedSettingStartsTheModelWithHTTPSOn() throws {
        let store = TestProcess.emptyStore()
        store.set(true, forKey: Defaults.Key.domainsHTTPS.rawValue)
        let model = ColimaModel(
            profile: "https-saved", domainProxy: FakeDomainProxy(), domainsStore: store, domainTLS: FakeDomainTLS())
        #expect(model.httpsEnabled)
        #expect(!ColimaModel(profile: "https-saved2", domainProxy: FakeDomainProxy()).httpsEnabled)
    }

    // MARK: Turning on

    @Test func turningHTTPSOnMakesTrustsAndListens() async throws {
        let r = try rig()
        await turnOn(r)
        #expect(r.model.domainStatus.https.phase == .running)
        #expect(r.model.domainStatus.https.port == 443)
        #expect(r.tls.events == ["prepare", "install", "identityTest", "selfTest 443"])
        #expect(r.proxy.httpsStarts == [[443]])
        #expect(r.model.httpsEnabled)
        #expect(r.store.object(forKey: Defaults.Key.domainsHTTPS.rawValue) as? Bool == true)
        #expect(r.dialogs.value == 1)
        #expect(r.model.domainURL("web.shop")?.absoluteString == "https://web.shop.localhost/")
    }

    @Test func theIdentityTestRunsOnceUntilHTTPSIsTurnedOff() async throws {
        let r = try rig()
        await turnOn(r)
        await r.model.startHTTPS()  // a second start, as a rebind makes it
        #expect(await running(r))
        #expect(r.tls.events.filter { $0 == "identityTest" }.count == 1)
        r.model.setHTTPS(false)
        #expect(await removed(r))
        await turnOn(r)
        #expect(r.tls.events.filter { $0 == "identityTest" }.count == 2)
    }

    @Test func aSecondClickDuringTheDialogAsksOnce() async throws {
        let r = try rig()
        r.model.setHTTPS(true)
        r.model.setHTTPS(true)
        #expect(await running(r))
        #expect(r.tls.events.filter { $0 == "install" }.count == 1)
    }

    @Test func aCancelledDialogLeavesHTTPSOffAndRemovesTheFiles() async throws {
        let r = try rig()
        r.tls.installOutcome = .cancelled
        r.model.setHTTPS(true)
        #expect(await waitUntil { r.model.domainStatus.https.problem != nil })
        #expect(r.model.domainStatus.https.phase == .off)
        #expect(r.model.domainStatus.https.caption == "You cancelled the password dialog. HTTPS stays off.")
        #expect(r.tls.events == ["prepare", "install", "removeFiles"])
        #expect(r.tls.ca == nil)
        #expect(!r.model.httpsEnabled)
        #expect(r.store.object(forKey: Defaults.Key.domainsHTTPS.rawValue) as? Bool != true)
        #expect(!r.model.httpsInstallPending)
        #expect(r.proxy.httpsStarts.isEmpty)
    }

    @Test func aTrustErrorLeavesHTTPSOffWithTheErrorNumber() async throws {
        let r = try rig()
        r.tls.installOutcome = .failed(-25293)
        r.model.setHTTPS(true)
        #expect(await waitUntil { r.model.domainStatus.https.problem != nil })
        #expect(r.model.domainStatus.https.caption == "HTTPS could not start: macOS error -25293.")
        #expect(r.tls.events.last == "removeFiles" && !r.model.httpsEnabled)
    }

    @Test func aMissingPortFallsBackTo8443() async throws {
        let r = try rig()
        r.proxy.busyHTTPSPorts = [443]
        await turnOn(r)
        #expect(r.model.domainStatus.https.port == 8443)
        #expect(r.proxy.httpsStarts == [[443], [8443]])
        #expect(r.model.domainStatus.https.caption == "Port 443 is busy, so HTTPS listens on port 8443.")
        #expect(r.model.domainURL("web.shop")?.absoluteString == "https://web.shop.localhost:8443/")
    }

    @Test func busyPortsFailAndALaterTryWorks() async throws {
        let r = try rig()
        r.proxy.busyHTTPSPorts = [443, 8443]
        r.model.setHTTPS(true)
        #expect(await waitUntil { r.model.domainStatus.https.phase == .failed })
        #expect(r.model.domainStatus.https.problem?.hasPrefix("Ports 443 and 8443 are busy.") == true)
        #expect(r.model.httpsEnabled)
        r.proxy.busyHTTPSPorts = []
        #expect(await running(r))
        // The retry makes no new dialog and no new CA.
        #expect(r.tls.events.filter { $0 == "install" || $0 == "prepare" }.count == 2)
    }

    @Test func ports443And8443PublishedByContainersFailWithoutBinding() async throws {
        let r = try rig()
        r.model.updateDomainRoutes(try containers(web("a", host: 443), web("b", host: 8443)))
        r.model.setHTTPS(true)
        #expect(await waitUntil { r.model.domainStatus.https.phase == .failed })
        #expect(r.proxy.httpsStarts.isEmpty)
        #expect(r.model.domainStatus.https.problem?.hasPrefix("Containers use ports 443 and 8443.") == true)
    }

    @Test func aFailedSelfTestSwitchesToOneCertificate() async throws {
        let r = try rig()
        r.tls.queueSelfTests([false, true])
        await turnOn(r)
        #expect(r.model.domainStatus.https.phase == .running)
        #expect(r.model.tlsMode == .multiSAN)
        #expect(r.proxy.httpsStarts == [[443], [443]])
        #expect(r.model.httpsStatusText.contains("one certificate"))
    }

    @Test func twoFailedSelfTestsStopHTTPS() async throws {
        let r = try rig()
        r.tls.queueSelfTests([false, false])
        r.model.setHTTPS(true)
        #expect(await waitUntil { r.model.domainStatus.https.phase == .failed })
        #expect(r.model.domainStatus.https.caption == "HTTPS could not start. The HTTPS self-test failed.")
        #expect(r.proxy.httpsPort == nil)
        #expect(r.proxy.httpsStops >= 1)
    }

    @Test func aFailedIdentityTestFailsHTTPS() async throws {
        let r = try rig()
        r.tls.identitiesWork = false
        r.model.setHTTPS(true)
        #expect(await waitUntil { r.model.domainStatus.https.phase == .failed })
        #expect(r.model.domainStatus.https.problem == "HTTPS could not start. The TLS identity test failed.")
        #expect(r.proxy.httpsStarts.isEmpty)
    }

    @Test func aMissingTrustOnlySetsTheUntrustedPhase() async throws {
        let r = try rig()
        r.tls.trusted = false
        r.model.setHTTPS(true)
        #expect(await waitUntil { r.model.domainStatus.https.phase == .untrusted })
        #expect(r.model.domainStatus.https.port == 443)
        #expect(r.model.httpsEnabled)
        // The proxy serves HTTPS, but links stay HTTP while the browsers would warn.
        r.model.setDomainHTTPStatus(phase: .running, httpPort: 80)
        #expect(r.model.domainURL("web.shop")?.absoluteString == "http://web.shop.localhost/")
    }

    @Test func trustAgainAsksOnceAndRechecks() async throws {
        let r = try rig()
        r.tls.trusted = false
        r.model.setHTTPS(true)
        #expect(await waitUntil { r.model.domainStatus.https.phase == .untrusted })
        let dialogs = r.dialogs.value
        r.tls.installOutcome = .cancelled
        r.model.trustCAAgain()
        #expect(await waitUntil { r.tls.events.filter { $0 == "install" }.count == 2 })
        try await Task.sleep(for: .milliseconds(50))
        #expect(r.model.domainStatus.https.phase == .untrusted)
        r.tls.installOutcome = .done
        r.tls.trusted = true
        r.model.trustCAAgain()
        #expect(await running(r))
        #expect(r.dialogs.value == dialogs + 2)
    }

    @Test func trustAgainDoesNothingWhileTrusted() async throws {
        let r = try rig()
        await turnOn(r)
        r.model.trustCAAgain()
        #expect(r.tls.events.filter { $0 == "install" }.count == 1)
    }

    // MARK: Turning off

    private func removed(_ r: Rig) async -> Bool {
        await waitUntil { r.model.domainStatus.https.phase == .off && r.model.domainStatus.https.problem != nil }
    }

    @Test func turningHTTPSOffRemovesTheCA() async throws {
        let r = try rig()
        await turnOn(r)
        r.model.setHTTPS(false)
        #expect(await removed(r))
        // The key file goes before the dialog.
        #expect(Array(r.tls.events.suffix(2)) == ["removeFiles", "uninstall"])
        #expect(r.proxy.httpsPort == nil && r.proxy.httpsStops >= 1)
        #expect(r.tls.ca == nil)
        #expect(r.model.domainStatus.https.caption == "ColimaBar removed the certificate authority.")
        #expect(r.store.object(forKey: Defaults.Key.domainsHTTPS.rawValue) as? Bool == false)
        #expect(r.dialogs.value == 2)
        #expect(r.model.domainURL("web.shop") == nil)
    }

    @Test func theKeyFileIsGoneWhileTheRemovalDialogShows() async throws {
        let r = try rig()
        await turnOn(r)
        let keyGone = Counter()
        let tls = r.tls
        tls.onUninstall { if tls.ca == nil { keyGone.add() } }
        r.model.setHTTPS(false)
        #expect(await removed(r))
        #expect(keyGone.value == 1)
    }

    @Test func aCancelledRemovalKeepsTheCertificateAndSaysSo() async throws {
        let r = try rig()
        await turnOn(r)
        r.tls.uninstallOutcome = .cancelled
        r.model.setHTTPS(false)
        #expect(await removed(r))
        #expect(Array(r.tls.events.suffix(2)) == ["removeFiles", "uninstall"])
        #expect(r.tls.ca == nil)
        let caption = try #require(r.model.domainStatus.https.caption)
        #expect(caption.contains("still lists the certificate authority and its trust setting"))
        #expect(caption.contains("Keychain Access"))
    }

    @Test func aFailedRemovalNamesTheError() async throws {
        let r = try rig()
        await turnOn(r)
        r.tls.uninstallOutcome = .failed(-1)
        r.model.setHTTPS(false)
        #expect(await removed(r))
        #expect(r.model.domainStatus.https.caption?.contains("error -1") == true)
        #expect(r.tls.ca == nil)
    }

    @Test func withoutFilesTheLabelledCertificatesGo() async throws {
        let r = try rig(https: true)
        r.model.setHTTPS(false)
        #expect(await removed(r))
        #expect(Array(r.tls.events.suffix(2)) == ["removeFiles", "uninstallLeftovers"])
        #expect(!r.tls.events.contains("uninstall"))
        #expect(r.model.domainStatus.https.caption == "ColimaBar removed the certificate authority.")
        #expect(!r.model.httpsEnabled)
    }

    @Test func aCancelledLeftoverRemovalSaysSo() async throws {
        let r = try rig(https: true)
        r.tls.leftoversOutcome = .cancelled
        r.model.setHTTPS(false)
        #expect(await removed(r))
        #expect(r.model.domainStatus.https.caption?.contains("Keychain Access") == true)
    }

    @Test func turningHTTPSOffWorksWhileTheMasterSwitchIsOff() async throws {
        let r = try rig(https: true, ca: true, domains: false)
        r.model.setHTTPS(false)
        #expect(await removed(r))
        #expect(r.tls.events == ["removeFiles", "uninstall"])
        #expect(!r.model.httpsEnabled && r.tls.ca == nil)
        // Turning it on still needs the master switch.
        r.model.setHTTPS(true)
        #expect(!r.tls.events.contains("install"))
    }

    @Test func theMasterSwitchOffWhileTheDialogShowsLeavesAConsistentState() async throws {
        let r = try rig()
        let model = r.model
        r.tls.onInstall { DispatchQueue.main.async { MainActor.assumeIsolated { model.domainsEnabled = false } } }
        r.model.setHTTPS(true)
        #expect(await waitUntil { !r.model.domainsEnabled })
        #expect(await waitUntil { r.model.httpsEnabled && r.model.domainStatus.https.phase == .off })
        #expect(r.proxy.httpsStarts.isEmpty)
        // The master switch on again starts HTTPS with the same CA and no dialog.
        r.model.domainsEnabled = true
        #expect(await running(r))
        #expect(r.tls.events.filter { $0 == "install" }.count == 1)
    }

    @Test func theSwitchesDuringARemovalDoNotRestartHTTPS() async throws {
        let r = try rig()
        await turnOn(r)
        r.model.setHTTPS(false)
        r.model.domainsEnabled = false
        r.model.domainsEnabled = true
        r.model.startHTTPSAtLaunch()
        #expect(await removed(r))
        try await Task.sleep(for: .milliseconds(100))
        #expect(r.proxy.httpsStarts.count == 1)
        #expect(r.proxy.httpsPort == nil)
    }

    @Test func theMasterSwitchOffStopsHTTPSButKeepsTheCA() async throws {
        let r = try rig()
        await turnOn(r)
        r.model.domainsEnabled = false
        #expect(await waitUntil { r.proxy.httpsPort == nil })
        #expect(r.model.httpsEnabled && r.tls.ca != nil)
        #expect(!r.tls.events.contains("uninstall") && !r.tls.events.contains("removeFiles"))
        #expect(r.model.domainStatus.https.phase == .off)
        // The master switch on again starts HTTPS with the same CA and no dialog.
        r.model.domainsEnabled = true
        #expect(await running(r))
        #expect(r.tls.events.filter { $0 == "install" || $0 == "prepare" }.count == 2)
        #expect(r.dialogs.value == 1)
    }

    // MARK: Launch

    @Test func aLaunchWithTheSettingOnStartsHTTPSWithoutADialog() async throws {
        let r = try rig(https: true, ca: true)
        r.model.startHTTPSAtLaunch()
        #expect(await running(r))
        #expect(!r.tls.events.contains("install") && !r.tls.events.contains("prepare"))
        #expect(r.dialogs.value == 0)
    }

    @Test func aLaunchWithTheSettingOffStartsNothing() async throws {
        let r = try rig(https: false, ca: true)
        r.model.startHTTPSAtLaunch()
        try await Task.sleep(for: .milliseconds(50))
        #expect(r.proxy.httpsStarts.isEmpty && r.tls.events.isEmpty)
    }

    @Test func aLaunchWithMissingFilesFailsAndDoesNotRemakeTheCA() async throws {
        let r = try rig(https: true, ca: false)
        r.model.startHTTPSAtLaunch()
        #expect(await waitUntil { r.model.domainStatus.https.phase == .failed })
        #expect(
            r.model.domainStatus.https.problem
                == "HTTPS could not start. The certificate authority files are missing or invalid. Turn HTTPS off and on."
        )
        try await Task.sleep(for: .milliseconds(150))
        #expect(r.model.domainStatus.https.phase == .failed)
        #expect(!r.tls.events.contains("prepare") && !r.tls.events.contains("install"))
        #expect(r.proxy.httpsStarts.isEmpty)
    }

    @Test func aLaunchWithoutTrustShowsTheUntrustedPhase() async throws {
        let r = try rig(https: true, ca: true)
        r.tls.trusted = false
        r.model.startHTTPSAtLaunch()
        #expect(await waitUntil { r.model.domainStatus.https.phase == .untrusted })
        #expect(!r.tls.events.contains("install"))
    }

    @Test func theLaunchTries443TwiceBefore8443() async throws {
        let r = try rig(https: true, ca: true)
        r.proxy.busyHTTPSPorts = [443]
        r.model.startHTTPSAtLaunch()
        #expect(await running(r))
        #expect(r.proxy.httpsStarts == [[443], [443], [8443]])
    }

    // MARK: After the start

    @Test func aFailedListenerTriesAgain() async throws {
        let r = try rig()
        await turnOn(r)
        r.proxy.failHTTPSListener()
        #expect(await waitUntil { r.model.domainStatus.https.phase == .failed })
        #expect(r.model.domainStatus.https.problem == "The HTTPS listener stopped. ColimaBar tries again soon.")
        #expect(await running(r))
        #expect(r.proxy.httpsStarts.count == 2)
    }

    @Test func aWakeRestartsAMissingListener() async throws {
        let r = try rig()
        await turnOn(r)
        r.model.httpsAfterWake()
        try await Task.sleep(for: .milliseconds(50))
        #expect(r.proxy.httpsStarts.count == 1)  // the listener lives: no restart
        r.proxy.stopHTTPS()
        r.model.httpsAfterWake()
        #expect(await waitUntil { r.proxy.httpsStarts.count == 2 && r.proxy.httpsPort == 443 })
        #expect(await running(r))
    }

    @Test func aContainerThatPublishesTheHTTPSPortMakesHTTPSMove() async throws {
        let r = try rig()
        await turnOn(r)
        r.model.updateDomainRoutes(try containers(web("a", host: 443)))
        #expect(
            await waitUntil { r.model.domainStatus.https.port == 8443 && r.model.domainStatus.https.phase == .running })
        #expect(r.proxy.httpsStarts.last == [8443])
    }

    @Test func aConflictRebindDropsThePortAtOnce() async throws {
        let r = try rig()
        await turnOn(r)
        let seen = Box<[DomainStatus.HTTPS]>([])
        let model = r.model
        r.proxy.onStartHTTPS { _ in
            let now = await MainActor.run { model.domainStatus.https }
            seen.mutate { $0.append(now) }
        }
        r.model.updateDomainRoutes(try containers(web("a", host: 443)))
        // The status changes in the same turn, before the listener starts again.
        #expect(r.model.domainStatus.https.phase == .settingUp && r.model.domainStatus.https.port == nil)
        #expect(r.model.domainURL("web.shop") == nil)
        #expect(
            await waitUntil { r.model.domainStatus.https.port == 8443 && r.model.domainStatus.https.phase == .running })
        #expect(seen.value.allSatisfy { $0.phase == .settingUp && $0.port == nil })
    }

    @Test func aListenerOnTheFallbackPortGoesBackTo443() async throws {
        let r = try rig()
        r.proxy.busyHTTPSPorts = [443]
        await turnOn(r)
        #expect(r.model.domainStatus.https.port == 8443)
        r.model.rebuildDomainRoutes()
        #expect(await waitUntil { !r.model.httpsMoveBackProbing })
        #expect(r.model.domainStatus.https.port == 8443)
        r.proxy.busyHTTPSPorts = []
        r.model.rebuildDomainRoutes()
        #expect(
            await waitUntil { r.model.domainStatus.https.port == 443 && r.model.domainStatus.https.phase == .running })
    }

    @Test func aFailedStartTriesAgainWhenThePublishedPortsChange() async throws {
        let r = try rig(failureRetry: 60)
        r.proxy.busyHTTPSPorts = [443, 8443]
        r.model.setHTTPS(true)
        #expect(await waitUntil { r.model.domainStatus.https.phase == .failed })
        let tries = r.proxy.httpsStarts.count
        r.proxy.busyHTTPSPorts = []
        r.model.updateDomainRoutes(try containers(web("a", host: 5000)))
        #expect(await running(r))
        #expect(r.proxy.httpsStarts.count > tries)
    }

    @Test func theFallbackModeMakesANewCertificateWhenTheRoutesChange() async throws {
        let r = try rig()
        r.tls.queueSelfTests([false, true])
        await turnOn(r)
        #expect(r.model.tlsMode == .multiSAN)
        let before = r.proxy.httpsStarts.count
        r.model.updateDomainRoutes(try containers(web("shop", host: 5000)))
        #expect(await waitUntil { r.proxy.httpsStarts.count == before + 1 })
        #expect(await running(r))
        #expect(r.model.multiSANServed.contains("shop.localhost"))
        // The same routes: no new certificate.
        r.model.rebuildDomainRoutes()
        try await Task.sleep(for: .milliseconds(150))
        #expect(r.proxy.httpsStarts.count == before + 1)
    }

    @Test func aStoppedVMKeepsTheNamesForTheCertificatesAndStartsNothing() async throws {
        let r = try rig()
        r.tls.queueSelfTests([false, true])
        await turnOn(r)
        r.model.updateDomainRoutes(try containers(web("shop", host: 5000)))
        #expect(await waitUntil { r.model.multiSANServed.contains("shop.localhost") })
        #expect(await running(r))
        // A debounced renewal of the names may still be due: let it end before the count.
        try await Task.sleep(for: .milliseconds(200))
        #expect(await running(r))
        let starts = r.proxy.httpsStarts.count
        r.model.setState(.stopped)
        r.model.updateDomainRoutes([], authoritative: false)
        r.model.rebuildDomainRoutes()
        let table = r.proxy.routes
        #expect(!table.vmRunning && table.routes.isEmpty)
        #expect(table.routeHost(for: "app.shop.localhost") == "shop.localhost")
        #expect(table.routeHost(for: "other.localhost") == nil)
        try await Task.sleep(for: .milliseconds(150))
        #expect(r.proxy.httpsStarts.count == starts)
        #expect(r.model.multiSANServed.contains("shop.localhost"))
    }

    @Test func theNamesOfAStoppedVMGoWhenHTTPSOrTheMasterSwitchTurnsOff() async throws {
        let r = try rig()
        await turnOn(r)
        r.model.updateDomainRoutes(try containers(web("shop", host: 5000)))
        r.model.setState(.stopped)
        r.model.updateDomainRoutes([], authoritative: false)
        r.model.rebuildDomainRoutes()
        #expect(r.proxy.routes.rememberedNames == ["shop"])
        r.model.setHTTPS(false)
        #expect(await removed(r))
        #expect(r.proxy.routes.rememberedNames.isEmpty)
        let master = try rig()
        await turnOn(master)
        master.model.updateDomainRoutes(try containers(web("shop", host: 5000)))
        master.model.setState(.stopped)
        master.model.updateDomainRoutes([], authoritative: false)
        master.model.rebuildDomainRoutes()
        master.model.domainsEnabled = false
        #expect(master.proxy.routes.rememberedNames.isEmpty)
    }

    @Test func aNewStartReplacesTheCache() async throws {
        let r = try rig()
        await turnOn(r)
        let old = try #require(r.model.leafCache)
        _ = old.identity(forSNI: "colimabar-selftest.localhost")
        await r.model.startHTTPS()
        #expect(r.model.leafCache !== old)
    }

    @Test func thePerNameModeNeverRestartsForARouteChange() async throws {
        let r = try rig()
        await turnOn(r)
        r.model.updateDomainRoutes(try containers(web("shop", host: 5000)))
        try await Task.sleep(for: .milliseconds(150))
        #expect(r.proxy.httpsStarts.count == 1)
    }

    // MARK: Replacing a CA

    @Test func aCAThatDoesNotCoverTheSuffixesStartsNoListener() async throws {
        let r = try rig(https: true, ca: true, permitted: ["old.test"])
        r.model.startHTTPSAtLaunch()
        #expect(await waitUntil { r.model.domainStatus.https.phase == .untrusted })
        let https = r.model.domainStatus.https
        #expect(https.port == nil && !https.listening)
        #expect(https.caption == ColimaModel.needsNewCAText)
        #expect(r.proxy.httpsStarts.isEmpty && r.tls.events.isEmpty)
        #expect(r.model.httpsStatusText.contains("not listening") && r.model.httpsStatusText.contains("trusted: no"))
        // A wake and the heartbeat do not change that or open a dialog.
        r.model.httpsAfterWake()
        r.model.httpsHeartbeat()
        try await Task.sleep(for: .milliseconds(50))
        #expect(r.model.domainStatus.https.phase == .untrusted && r.dialogs.value == 0)
    }

    @Test func trustAgainReplacesACAThatDoesNotCoverTheSuffixes() async throws {
        let r = try rig(https: true, ca: true, permitted: ["old.test"])
        let old = try #require(r.tls.ca)
        r.model.startHTTPSAtLaunch()
        #expect(await waitUntil { r.model.domainStatus.https.phase == .untrusted })
        r.model.trustCAAgain()
        #expect(await running(r))
        // The old CA goes first (trust and certificate), then the new one is made and trusted.
        #expect(r.tls.events == ["uninstall", "prepare", "install", "identityTest", "selfTest 443"])
        let new = try #require(r.tls.ca)
        #expect(Set(new.permitted) == ["localhost"] && new.der != old.der)
        #expect(r.model.httpsEnabled && !r.model.httpsInstallPending)
        #expect(r.dialogs.value == 1)
    }

    @Test func aCancelledReplacementKeepsTheOldCAWithItsFiles() async throws {
        let r = try rig(https: true, ca: true, permitted: ["old.test"])
        let old = try #require(r.tls.ca)
        r.model.startHTTPSAtLaunch()
        #expect(await waitUntil { r.model.domainStatus.https.phase == .untrusted })
        r.tls.uninstallOutcome = .cancelled
        r.model.trustCAAgain()
        #expect(
            await waitUntil { r.model.domainStatus.https.problem?.hasPrefix("ColimaBar did not replace") == true })
        #expect(r.model.domainStatus.https.phase == .untrusted)
        #expect(r.tls.events == ["uninstall"])
        #expect(r.tls.ca?.der == old.der && r.model.httpsEnabled)
        // The next try works.
        r.tls.uninstallOutcome = .done
        r.model.trustCAAgain()
        #expect(await running(r))
    }

    @Test func aCancelledSecondDialogLeavesNoCAAndHTTPSOff() async throws {
        let r = try rig(https: true, ca: true, permitted: ["old.test"])
        r.model.startHTTPSAtLaunch()
        #expect(await waitUntil { r.model.domainStatus.https.phase == .untrusted })
        r.tls.installOutcome = .cancelled
        r.model.trustCAAgain()
        #expect(await waitUntil { r.model.domainStatus.https.phase == .off })
        #expect(r.tls.events == ["uninstall", "prepare", "install", "removeFiles"])
        #expect(r.tls.ca == nil && !r.model.httpsEnabled && !r.model.httpsInstallPending)
        #expect(r.store.object(forKey: Defaults.Key.domainsHTTPS.rawValue) as? Bool == false)
    }

    @Test func nothingStartsHTTPSWhileAReplacementWaitsForItsDialog() async throws {
        let r = try rig(https: true, ca: true, permitted: ["old.test"])
        r.model.startHTTPSAtLaunch()
        #expect(await waitUntil { r.model.domainStatus.https.phase == .untrusted })
        r.tls.onUninstall { Thread.sleep(forTimeInterval: 0.3) }
        r.model.trustCAAgain()
        await r.model.startHTTPS()
        r.model.startHTTPSAtLaunch()
        r.model.httpsAfterWake()
        r.model.httpsHeartbeat()
        r.model.setHTTPS(false)
        try await Task.sleep(for: .milliseconds(100))
        #expect(r.proxy.httpsStarts.isEmpty)
        #expect(r.model.httpsEnabled)
        #expect(await running(r))
        #expect(r.proxy.httpsStarts == [[443]])
    }

    // MARK: Install marker

    @Test func theMarkerStandsWhileTheInstallDialogShows() async throws {
        let r = try rig()
        let during = Counter()
        let key = Defaults.Key.domainsHTTPSPending.rawValue
        nonisolated(unsafe) let store = r.store
        r.tls.onInstall { if store.bool(forKey: key) { during.add() } }
        await turnOn(r)
        #expect(during.value == 1)
        #expect(!r.model.httpsInstallPending)
    }

    @Test func aLaunchAfterAnInterruptedInstallKeepsACAThatMacOSTrusts() async throws {
        let r = try rig(https: false, ca: true, pending: true)
        #expect(r.model.httpsInstallPending)
        r.model.startHTTPSAtLaunch()
        #expect(await running(r))
        #expect(r.model.httpsEnabled && !r.model.httpsInstallPending)
        #expect(r.store.object(forKey: Defaults.Key.domainsHTTPS.rawValue) as? Bool == true)
        #expect(!r.tls.events.contains("install") && r.dialogs.value == 0)
    }

    @Test func aLaunchAfterAnInterruptedInstallDeletesACAThatMacOSDoesNotTrust() async throws {
        let r = try rig(https: false, ca: true, pending: true)
        r.tls.trusted = false
        r.model.startHTTPSAtLaunch()
        #expect(await waitUntil { !r.model.httpsInstallPending })
        // No dialog: a certificate without trust settings goes by a plain delete.
        #expect(Array(r.tls.events.suffix(2)) == ["deleteCertificate", "removeFiles"])
        #expect(!r.tls.events.contains("uninstall"))
        #expect(r.tls.ca == nil && !r.model.httpsEnabled)
        #expect(r.proxy.httpsStarts.isEmpty && r.dialogs.value == 0)
    }

    @Test func aLaunchAfterAnInterruptedInstallKeepsACAWithTrustSettingsAndNeverUninstalls() async throws {
        let r = try rig(https: false, ca: true, pending: true)
        r.tls.trusted = false
        r.tls.hasSettings = true
        r.model.startHTTPSAtLaunch()
        #expect(await waitUntil { r.model.domainStatus.https.phase == .untrusted })
        #expect(r.model.httpsEnabled && !r.model.httpsInstallPending)
        #expect(r.tls.ca != nil)
        #expect(!r.tls.events.contains("uninstall") && !r.tls.events.contains("deleteCertificate"))
        #expect(r.dialogs.value == 0)
    }

    @Test func theMasterSwitchDuringTheInstallDialogNeverDeletesTheCAThatInstalls() async throws {
        let r = try rig()
        r.tls.trusted = false
        r.tls.hasSettings = false
        r.tls.onInstall { Thread.sleep(forTimeInterval: 0.3) }
        r.model.setHTTPS(true)
        #expect(await waitUntil { r.tls.events.contains("install") })
        #expect(r.model.httpsInstallPending)
        r.model.domainsEnabled = false
        r.model.domainsEnabled = true
        r.model.startHTTPSAtLaunch()
        #expect(await waitUntil { r.model.httpsEnabled })
        #expect(!r.model.httpsInstallPending)
        #expect(!r.tls.events.contains("removeFiles") && !r.tls.events.contains("deleteCertificate"))
        #expect(!r.tls.events.contains("uninstall"))
        #expect(r.tls.ca != nil)
    }

    @Test func theLaunchCleanUpRunsOnceAndBlocksTheSwitchesWhileItRuns() async throws {
        let r = try rig(https: false, ca: true, pending: true)
        r.tls.hasSettings = false
        r.model.startHTTPSAtLaunch()
        r.model.startHTTPSAtLaunch()
        r.model.setHTTPS(true)
        #expect(await waitUntil { !r.model.httpsInstallPending })
        #expect(r.tls.events.filter { $0 == "deleteCertificate" }.count == 1)
        #expect(!r.model.httpsEnabled && r.tls.events.filter { $0 == "prepare" }.isEmpty)
    }

    // MARK: Removal marker

    @Test func theRemovalMarkerStandsWhileTheRemovalDialogShows() async throws {
        let r = try rig()
        await turnOn(r)
        let during = Counter()
        let key = Defaults.Key.domainsHTTPSRemoving.rawValue
        nonisolated(unsafe) let store = r.store
        r.tls.onUninstall { if store.bool(forKey: key) { during.add() } }
        r.model.setHTTPS(false)
        #expect(await removed(r))
        #expect(during.value == 1)
        #expect(!r.model.httpsRemovalPending)
    }

    @Test func aQuitDuringTheRemovalDialogKeepsTheMarker() async throws {
        let r = try rig()
        await turnOn(r)
        r.tls.onUninstall { Thread.sleep(forTimeInterval: 0.2) }
        r.model.setHTTPS(false)
        #expect(await waitUntil { r.tls.events.contains("uninstall") })
        r.model.stopHTTPSForQuit()
        try await Task.sleep(for: .milliseconds(400))
        #expect(r.model.httpsRemovalPending)
    }

    @Test func aLaunchWithTheRemovalMarkerOffersACleanUpAndRunsNothing() async throws {
        let r = try rig(https: false, removing: true)
        r.model.startHTTPSAtLaunch()
        try await Task.sleep(for: .milliseconds(60))
        let https = r.model.domainStatus.https
        #expect(https.phase == .off && https.offersCleanUp)
        #expect(https.caption?.contains("Delete the certificate \"ColimaBar Local CA\"") == true)
        #expect(r.tls.events.isEmpty && r.dialogs.value == 0)
        #expect(r.model.httpsRemovalPending)
    }

    @Test func theCleanUpButtonRemovesTheLabelledCertificatesAndClearsTheMarker() async throws {
        let r = try rig(https: false, removing: true)
        r.model.startHTTPSAtLaunch()
        try await Task.sleep(for: .milliseconds(60))
        r.model.cleanUpLeftoverCA()
        #expect(await removed(r))
        #expect(r.tls.events == ["uninstallLeftovers"])
        #expect(!r.model.httpsRemovalPending && !r.model.domainStatus.https.offersCleanUp)
        #expect(r.model.domainStatus.https.caption == "ColimaBar removed the certificate authority.")
        #expect(r.dialogs.value == 1)
    }

    @Test func theCleanUpDoesNothingWithoutTheOffer() throws {
        let r = try rig()
        r.model.cleanUpLeftoverCA()
        #expect(r.tls.events.isEmpty)
    }

    @Test func aLaunchAfterAnInterruptedInstallWithoutFilesClearsTheMarker() async throws {
        let r = try rig(https: false, ca: false, pending: true)
        r.model.startHTTPSAtLaunch()
        #expect(await waitUntil { !r.model.httpsInstallPending })
        #expect(!r.model.httpsEnabled && r.proxy.httpsStarts.isEmpty)
    }

    @Test func aMarkerWithTheSettingOnIsJustCleared() async throws {
        let r = try rig(https: true, ca: true, pending: true)
        r.model.startHTTPSAtLaunch()
        #expect(await running(r))
        #expect(!r.model.httpsInstallPending && !r.tls.events.contains("removeFiles"))
    }

    @Test func quitWhileTheDialogShowsChangesNoStateAndKeepsTheMarker() async throws {
        let r = try rig()
        r.tls.onInstall { Thread.sleep(forTimeInterval: 0.2) }
        r.model.setHTTPS(true)
        #expect(await waitUntil { r.tls.events.contains("install") })
        r.model.stopHTTPSForQuit()
        try await Task.sleep(for: .milliseconds(400))
        #expect(!r.model.httpsEnabled && r.proxy.httpsStarts.isEmpty)
        #expect(r.model.httpsInstallPending)
        #expect(!r.tls.events.contains("removeFiles"))
    }

    // MARK: The trust changes

    @Test func aWakeNoticesAChangedTrust() async throws {
        let r = try rig()
        await turnOn(r)
        r.tls.trusted = false
        r.model.httpsAfterWake()
        #expect(await waitUntil { r.model.domainStatus.https.phase == .untrusted })
        #expect(r.model.domainStatus.https.port == 443)
        #expect(r.model.domainURL("web.shop") == nil || r.model.domainURL("web.shop")?.scheme == "http")
        r.tls.trusted = true
        r.model.httpsAfterWake()
        #expect(await running(r))
    }

    @Test func theHeartbeatChecksTheTrustAtMostOnceInTheGap() async throws {
        let slow = try rig(trustRecheck: 3600)
        await turnOn(slow)
        slow.tls.trusted = false
        slow.model.httpsHeartbeat()
        try await Task.sleep(for: .milliseconds(80))
        #expect(slow.model.domainStatus.https.phase == .running)
        let fast = try rig(trustRecheck: 0)
        await turnOn(fast)
        fast.tls.trusted = false
        fast.model.httpsHeartbeat()
        #expect(await waitUntil { fast.model.domainStatus.https.phase == .untrusted })
    }

    @Test func aTrustCheckThatEndsAfterAStopChangesNothing() async throws {
        let r = try rig(trustRecheck: 0)
        await turnOn(r)
        r.tls.trusted = false
        r.model.httpsHeartbeat()
        r.model.tearDownHTTPS()
        r.model.setHTTPSStatus(.init(phase: .failed, problem: "x"))
        try await Task.sleep(for: .milliseconds(100))
        #expect(r.model.domainStatus.https.phase == .failed)
    }

    // MARK: Status while the listener moves

    @Test func aMoveKeepsTheStatusAndLinksUntilTheNewPortIsBound() async throws {
        let r = try rig()
        r.proxy.busyHTTPSPorts = [443]
        await turnOn(r)
        #expect(r.model.domainStatus.https.port == 8443)
        let seen = Box<[DomainStatus.HTTPS]>([])
        let model = r.model
        r.proxy.onStartHTTPS { _ in
            let now = await MainActor.run { model.domainStatus.https }
            seen.mutate { $0.append(now) }
        }
        r.proxy.busyHTTPSPorts = []
        r.model.rebuildDomainRoutes()
        #expect(
            await waitUntil { r.model.domainStatus.https.port == 443 && r.model.domainStatus.https.phase == .running })
        let phases = seen.value
        #expect(!phases.isEmpty)
        #expect(phases.allSatisfy { $0.phase == .running && $0.port == 8443 })
    }

    @Test func aFirstStartShowsTheSettingUpPhase() async throws {
        let r = try rig(https: true, ca: true)
        let seen = Box<[DomainStatus.HTTPS.Phase]>([])
        let model = r.model
        r.proxy.onStartHTTPS { _ in
            let now = await MainActor.run { model.domainStatus.https.phase }
            seen.mutate { $0.append(now) }
        }
        r.model.startHTTPSAtLaunch()
        #expect(await running(r))
        #expect(seen.value == [.settingUp])
    }

    // MARK: Captions and diagnostics

    @Test func eachProblemHasItsOwnCaption() async throws {
        let r = try rig()
        r.proxy.busyHTTPSPorts = [443, 8443]
        r.model.setHTTPS(true)
        #expect(await waitUntil { r.model.domainStatus.https.phase == .failed })
        let busy = try #require(r.model.domainStatus.https.caption)
        #expect(busy.hasPrefix("Ports 443 and 8443 are busy.") && !busy.hasPrefix("HTTPS could not start."))
        r.proxy.busyHTTPSPorts = []
        #expect(await running(r))
        r.proxy.failHTTPSListener()
        #expect(await waitUntil { r.model.domainStatus.https.phase == .failed })
        #expect(
            r.model.domainStatus.https.caption == "The HTTPS listener stopped. ColimaBar tries again soon.")
    }

    @Test func theDiagnosticsSayUnknownWhenTheTrustIsUnknown() async throws {
        let r = try rig()
        r.proxy.busyHTTPSPorts = [443, 8443]
        r.model.setHTTPS(true)
        #expect(await waitUntil { r.model.domainStatus.https.phase == .failed })
        #expect(
            r.model.httpsStatusText.hasPrefix("failed,") && r.model.httpsStatusText.hasSuffix("CA trusted: unknown"))
        r.tls.trusted = false
        r.proxy.busyHTTPSPorts = []
        #expect(await waitUntil { r.model.domainStatus.https.phase == .untrusted })
        #expect(r.model.httpsStatusText.hasSuffix("CA trusted: no"))
    }

    // MARK: The fallback certificate

    @Test func theFallbackCertificateIsMadeAgainBeforeItExpires() async throws {
        let r = try rig(multiSANRenew: 0.1)
        r.tls.queueSelfTests([false, true])
        await turnOn(r)
        #expect(r.model.tlsMode == .multiSAN)
        #expect(await waitUntil { r.proxy.httpsStarts.count >= 4 })
        #expect(r.model.domainStatus.https.phase == .running)
        // A stop ends the timer.
        r.model.tearDownHTTPS()
        let count = r.proxy.httpsStarts.count
        try await Task.sleep(for: .milliseconds(300))
        #expect(r.proxy.httpsStarts.count == count && r.proxy.httpsPort == nil)
    }

    @Test func aRenewalStartsTheNewListenerBeforeTheOldCertificateGoes() async throws {
        let r = try rig(multiSANRenew: 0.1)
        r.tls.queueSelfTests([false, true])
        await turnOn(r)
        #expect(r.model.tlsMode == .multiSAN)
        let cache = try #require(r.model.leafCache)
        // The old listener serves this certificate.
        _ = cache.multiSANIdentity(names: ["a.localhost"], epoch: r.model.multiSANEpoch)
        let epoch = r.model.multiSANEpoch
        let atStart = Box<[Int]>([])
        r.proxy.onStartHTTPS { _ in atStart.mutate { $0.append(cache.leafCount) } }
        #expect(await waitUntil { r.model.multiSANEpoch > epoch && cache.leafCount == 0 })
        // At the first start of the renewal the old certificate was still there.
        #expect(atStart.value.first == 1)
        #expect(r.model.domainStatus.https.phase == .running)
    }

    @Test func aStopWhileTheFallbackCertificateChangesWins() async throws {
        let r = try rig()
        r.tls.queueSelfTests([false, true])
        await turnOn(r)
        let before = r.proxy.httpsStarts.count
        r.model.updateDomainRoutes(try containers(web("shop", host: 5000)))
        r.model.setHTTPS(false)
        #expect(await removed(r))
        try await Task.sleep(for: .milliseconds(200))
        #expect(r.proxy.httpsStarts.count == before)
        #expect(r.proxy.httpsPort == nil && r.model.domainStatus.https.phase == .off)
    }

    // MARK: Claims and restart hints

    private func stopped(_ id: String) -> String {
        """
        {"Id":"\(id)","Names":["/\(id)"],"Image":"x","State":"exited","Status":"Exited (0) 1 second ago","Created":1}
        """
    }

    @Test func aStartSkipsAPortThatAStoppedContainerClaims() async throws {
        let r = try rig()
        r.model.updateDomainRoutes(try containers(web("web", host: 443)))
        r.model.updateDomainRoutes(try containers(stopped("web")))
        await turnOn(r)
        #expect(r.model.domainStatus.https.port == 8443)
        #expect(r.proxy.httpsStarts == [[8443]])
        #expect(r.model.domainRestartHints.isEmpty)
    }

    @Test func aStoppedContainerKeepsHTTPSOffItsPort() async throws {
        let r = try rig()
        await turnOn(r)
        r.model.updateDomainRoutes(try containers(web("web", host: 443)))
        #expect(
            await waitUntil { r.model.domainStatus.https.port == 8443 && r.model.domainStatus.https.phase == .running })
        r.model.updateDomainRoutes(try containers(stopped("web")))
        r.model.rebuildDomainRoutes()
        r.model.domainsHeartbeat()
        try await Task.sleep(for: .milliseconds(100))
        #expect(r.model.domainStatus.https.port == 8443)
    }

    @Test func anHTTPSConflictRebindShowsTheRestartHint() async throws {
        let r = try rig()
        await turnOn(r)
        r.model.updateDomainRoutes(try containers(web("web", host: 443)))
        #expect(
            await waitUntil { r.model.domainStatus.https.port == 8443 && r.model.domainStatus.https.phase == .running })
        #expect(r.model.domainRestartHints.map(\.id) == ["web"])
        #expect(r.model.domainRestartHints.first?.port == 443)
        #expect(r.model.alerts.count == 1)
        r.model.updateDomainRoutes(try containers(web("web", host: 443)))
        #expect(r.model.alerts.count == 1)
    }

    // MARK: Diagnostics

    @Test func theDiagnosticsLineHoldsTheStateAndNoNames() async throws {
        let r = try rig()
        #expect(r.model.httpsStatusText == "off")
        await turnOn(r)
        r.model.updateDomainRoutes(try containers(web("secretname", host: 5000)))
        let text = r.model.httpsStatusText
        #expect(
            text
                == "listening on port 443, identity: in memory, a certificate for each name, leaves made: 0, CA trusted: yes"
        )
        #expect(!text.contains("secretname"))
    }

    // MARK: The dashboard comes back after a dialog

    @Test func theDashboardComesBackAfterEnablingHTTPS() async throws {
        let r = try rig(dashboardOpen: true)
        await turnOn(r)
        #expect(await waitUntil { r.restores.value == 1 })
    }

    @Test func theDashboardComesBackAfterACancelledDialog() async throws {
        let r = try rig(dashboardOpen: true)
        r.tls.installOutcome = .cancelled
        r.model.setHTTPS(true)
        #expect(await waitUntil { r.restores.value == 1 })
    }

    @Test func theDashboardComesBackAfterDisablingHTTPS() async throws {
        let r = try rig(dashboardOpen: true)
        await turnOn(r)
        #expect(await waitUntil { r.restores.value == 1 })
        r.model.setHTTPS(false)
        #expect(await removed(r))
        #expect(await waitUntil { r.restores.value == 2 })
    }

    @Test func theDashboardComesBackAfterTrustAgainAndAReplacement() async throws {
        let r = try rig(https: true, ca: true, permitted: ["old.test"], dashboardOpen: true)
        r.model.startHTTPSAtLaunch()
        #expect(await waitUntil { r.model.domainStatus.https.phase == .untrusted })
        r.tls.uninstallOutcome = .cancelled
        r.model.trustCAAgain()
        #expect(await waitUntil { r.restores.value == 1 })
        r.tls.uninstallOutcome = .done
        r.model.trustCAAgain()
        #expect(await running(r))
        #expect(await waitUntil { r.restores.value == 2 })
    }

    @Test func theDashboardComesBackAfterDeletingTheCertificate() async throws {
        let r = try rig(https: false, removing: true, dashboardOpen: true)
        r.model.startHTTPSAtLaunch()
        try await Task.sleep(for: .milliseconds(60))
        r.model.cleanUpLeftoverCA()
        #expect(await removed(r))
        #expect(await waitUntil { r.restores.value == 1 })
    }

    @Test func aClosedDashboardStaysClosedAfterADialog() async throws {
        let r = try rig()
        await turnOn(r)
        r.model.setHTTPS(false)
        #expect(await removed(r))
        try await Task.sleep(for: .milliseconds(50))
        #expect(r.restores.value == 0)
    }
}
