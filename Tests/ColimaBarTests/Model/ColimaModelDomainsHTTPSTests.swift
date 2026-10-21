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
    }

    private func rig(
        https: Bool = false, ca: Bool = false, domains: Bool = true, gap: TimeInterval = 0,
        failureRetry: TimeInterval = 0.05
    ) throws -> Rig {
        let proxy = FakeDomainProxy()
        let tls = FakeDomainTLS()
        if ca { tls.ca = try LocalCA.create(permitted: ["localhost"]) }
        let store = TestProcess.emptyStore()
        let model = ColimaModel(
            profile: "https-life-\(UUID().uuidString.prefix(6))", domainProxy: proxy, domainsEnabled: domains,
            domainsStore: store, httpsEnabled: https, domainTLS: tls)
        model.domainTimings = DomainTimings(
            launchRetry: 0.01, failureRetry: failureRetry, rebindGap: gap, multiSANDebounce: 0.05)
        model.setState(.running)
        let dialogs = Counter()
        model.dismissPopover = { dialogs.add() }
        return Rig(model: model, proxy: proxy, tls: tls, store: store, dialogs: dialogs)
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
        #expect(r.tls.events == ["prepare", "install", "makeProvider", "selfTest 443"])
        #expect(r.proxy.httpsStarts == [[443]])
        #expect(r.model.httpsEnabled)
        #expect(r.store.object(forKey: Defaults.Key.domainsHTTPS.rawValue) as? Bool == true)
        #expect(r.dialogs.value == 1)
        #expect(r.model.domainURL("web.shop")?.absoluteString == "https://web.shop.localhost/")
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
        #expect(r.store.object(forKey: Defaults.Key.domainsHTTPS.rawValue) == nil)
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

    @Test func noWorkingIdentityProviderFailsHTTPS() async throws {
        let r = try rig()
        r.tls.providerWorks = false
        r.model.setHTTPS(true)
        #expect(await waitUntil { r.model.domainStatus.https.phase == .failed })
        #expect(r.model.domainStatus.https.problem == "The TLS identity test failed.")
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

    @Test func turningHTTPSOffRemovesTheCA() async throws {
        let r = try rig()
        await turnOn(r)
        let provider = try #require(r.tls.providers.first)
        r.model.setHTTPS(false)
        #expect(await waitUntil { !r.model.httpsEnabled })
        #expect(Array(r.tls.events.suffix(2)) == ["uninstall", "removeFiles"])
        #expect(r.proxy.httpsPort == nil && r.proxy.httpsStops >= 1)
        #expect(provider.removeCount == 1)
        #expect(r.tls.ca == nil)
        #expect(r.model.domainStatus.https.phase == .off)
        #expect(r.model.domainStatus.https.caption == "ColimaBar removed the certificate authority.")
        #expect(r.store.object(forKey: Defaults.Key.domainsHTTPS.rawValue) as? Bool == false)
        #expect(r.dialogs.value == 2)
        #expect(r.model.domainURL("web.shop") == nil)
    }

    @Test func aCancelledRemovalStillDeletesTheKeyAndSaysSo() async throws {
        let r = try rig()
        await turnOn(r)
        r.tls.uninstallOutcome = .cancelled
        r.model.setHTTPS(false)
        #expect(await waitUntil { !r.model.httpsEnabled })
        #expect(Array(r.tls.events.suffix(2)) == ["uninstall", "removeFiles"])
        #expect(r.tls.ca == nil)
        #expect(
            r.model.domainStatus.https.caption
                == "macOS still lists a trust setting for the removed certificate authority. It has no effect, because the key is deleted."
        )
    }

    @Test func aFailedRemovalNamesTheError() async throws {
        let r = try rig()
        await turnOn(r)
        r.tls.uninstallOutcome = .failed(-1)
        r.model.setHTTPS(false)
        #expect(await waitUntil { !r.model.httpsEnabled })
        #expect(r.model.domainStatus.https.caption?.contains("error -1") == true)
        #expect(r.tls.ca == nil)
    }

    @Test func turningHTTPSOffWithNoFilesTellsTheUser() async throws {
        let r = try rig(https: true)
        r.model.setHTTPS(false)
        #expect(await waitUntil { !r.model.httpsEnabled })
        #expect(!r.tls.events.contains("uninstall"))
        #expect(r.model.domainStatus.https.caption?.contains("found no certificate authority file") == true)
    }

    @Test func theMasterSwitchOffStopsHTTPSButKeepsTheCA() async throws {
        let r = try rig()
        await turnOn(r)
        let provider = try #require(r.tls.providers.first)
        r.model.domainsEnabled = false
        #expect(await waitUntil { r.proxy.httpsPort == nil })
        #expect(provider.removeCount == 1)
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
                == "The certificate authority files are missing. Turn HTTPS off and on.")
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
        #expect(r.model.domainStatus.https.problem == "The listener stopped. ColimaBar tries again soon.")
        #expect(await running(r))
        #expect(r.proxy.httpsStarts.count == 2)
    }

    @Test func aWakeUnlocksTheKeychainAndRestartsAMissingListener() async throws {
        let r = try rig()
        await turnOn(r)
        let provider = try #require(r.tls.providers.first)
        r.model.httpsAfterWake()
        #expect(provider.unlockCount == 1)
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

    @Test func thePerNameModeNeverRestartsForARouteChange() async throws {
        let r = try rig()
        await turnOn(r)
        r.model.updateDomainRoutes(try containers(web("shop", host: 5000)))
        try await Task.sleep(for: .milliseconds(150))
        #expect(r.proxy.httpsStarts.count == 1)
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
                == "listening on port 443, identity: recording, a certificate for each name, leaves made: 0, CA trusted: yes"
        )
        #expect(!text.contains("secretname"))
    }
}
