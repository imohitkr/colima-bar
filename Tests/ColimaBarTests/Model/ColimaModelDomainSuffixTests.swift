import Foundation
import Testing

@testable import ColimaBar

/// The model glue of the custom suffix. The model has a fake DNS server, a fake
/// `osascript` runner, a resolver folder in a temporary place and fake TLS
/// services: no test runs `osascript`, writes `/etc`, binds a DNS port or
/// touches a keychain.
@MainActor @Suite struct ColimaModelDomainSuffixTests {
    private struct Rig {
        let model: ColimaModel
        let dns: FakeDNSResponder
        let runner: FakeResolverRunner
        let tls: FakeDomainTLS
        let proxy: FakeDomainProxy
        let store: UserDefaults
        let dir: String
        let dialogs: Counter
        let restores: Counter
        func file(_ suffix: String) -> String { "\(dir)/\(suffix)" }
    }

    private func rig(
        suffix: String? = nil, port: Int? = 25000, domains: Bool = true, https: Bool = false, ca: Bool = false,
        file: Bool = true, resolves: Bool = true, dashboardOpen: Bool = false
    ) throws -> Rig {
        let dns = FakeDNSResponder()
        let runner = FakeResolverRunner()
        let tls = FakeDomainTLS()
        let proxy = FakeDomainProxy()
        if ca { tls.ca = try LocalCA.create(permitted: ["localhost"] + [suffix].compactMap { $0 }) }
        let store = TestProcess.emptyStore()
        if let port { store.set(port, forKey: Defaults.Key.domainDNSPort.rawValue) }
        let model = ColimaModel(
            profile: "suffix-\(UUID().uuidString.prefix(6))", domainProxy: proxy, domainsEnabled: domains,
            domainsStore: store, httpsEnabled: https, domainTLS: tls, domainSuffix: suffix)
        let dir = NSTemporaryDirectory() + "cb-model-resolver-\(UUID().uuidString.prefix(8))"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        model.dnsResponder = dns
        model.resolverRun = runner.runner
        model.resolverDir = dir
        model.resolverCheck = { _ in resolves }
        model.dnsPortFree = { _ in true }
        model.domainTimings = DomainTimings(launchRetry: 0.01, failureRetry: 0.05, rebindGap: 0, multiSANDebounce: 0.05)
        model.setState(.running)
        let dialogs = Counter()
        model.dismissPopover = { dialogs.add() }
        let restores = Counter()
        model.restoreDashboard = { restores.add() }
        if dashboardOpen { model.visibleCount = 1 }
        if let suffix, file {
            try ResolverFile.content(port: port ?? 25000).write(
                toFile: "\(dir)/\(suffix)", atomically: true, encoding: .utf8)
        }
        // Like the root shell: a successful run writes the new file.
        runner.onSuccess {
            guard let script = runner.calls.last?.last,
                let name = script.firstMatch(of: /N='([^']*)'/)?.1, !name.isEmpty,
                let port = script.firstMatch(of: /P=(\d+)/)?.1
            else { return }
            try? ResolverFile.content(port: Int(port) ?? 0).write(
                toFile: "\(dir)/\(name)", atomically: true, encoding: .utf8)
        }
        return Rig(
            model: model, dns: dns, runner: runner, tls: tls, proxy: proxy, store: store, dir: dir, dialogs: dialogs,
            restores: restores)
    }

    private func web(_ id: String) -> String {
        """
        {"Id":"\(id)","Names":["/\(id)"],"Image":"x","State":"running","Status":"Up","Created":1,
         "Ports":[{"IP":"0.0.0.0","PublicPort":5000,"PrivatePort":80,"Type":"tcp"}],
         "Labels":{"com.docker.compose.project":"shop","com.docker.compose.service":"web"}}
        """
    }

    private func list() throws -> [APIContainer] {
        try JSONDecoder().decode([APIContainer].self, from: Data(("[" + web("w1") + "]").utf8))
    }

    /// The runner of the fake writes the file with the stored port, so the test stores it first.
    private func apply(_ r: Rig, _ suffix: String) async {
        await r.model.applySuffix(suffix)
    }

    // MARK: Safety

    @Test func aDebugRunNeverWritesAnythingOrRunsAnything() async throws {
        let runner = FakeResolverRunner()
        let dns = FakeDNSResponder()
        let store = TestProcess.emptyStore()
        let model = ColimaModel(
            profile: "suffix-debug", readOnly: true, domainProxy: FakeDomainProxy(), domainsEnabled: true,
            domainsStore: store, domainTLS: FakeDomainTLS(), domainSuffix: "colima.internal")
        model.dnsResponder = dns
        model.resolverRun = runner.runner
        await model.applySuffix("dev.test")
        await model.removeSuffix()
        await model.repairDNS()
        await model.startDNSResponder()
        #expect(runner.calls.isEmpty && dns.starts.isEmpty)
        #expect(store.object(forKey: Defaults.Key.domainSuffix.rawValue) == nil)
        #expect(model.domainSuffix == "colima.internal")
    }

    @Test func aModelInATestProcessGetsInertSeamsThatRunNothing() async throws {
        let model = ColimaModel(profile: "suffix-inert", domainProxy: FakeDomainProxy(), domainsEnabled: true)
        #expect(model.dnsResponder is InertDNSResponder)
        #expect(!model.resolverDir.hasPrefix("/etc"))
        model.dnsPortFree = { _ in true }
        // The system runner refuses in a test process: no osascript runs.
        await model.applySuffix("colima.internal")
        #expect(model.domainSuffix == nil)
        #expect(model.domainStatus.dns.note?.hasPrefix("ColimaBar could not write the resolver file") == true)
    }

    @Test func theSuffixIsNotInTheSettingsFileAndABadStoredValueIsIgnored() throws {
        let store = TestProcess.emptyStore()
        store.set("dev", forKey: Defaults.Key.domainSuffix.rawValue)
        let model = ColimaModel(
            profile: "suffix-bad", domainProxy: FakeDomainProxy(), domainsEnabled: true, domainsStore: store)
        #expect(model.domainSuffix == nil)
        store.set("Dev.Test", forKey: Defaults.Key.domainSuffix.rawValue)
        let again = ColimaModel(
            profile: "suffix-ok", domainProxy: FakeDomainProxy(), domainsEnabled: true, domainsStore: store)
        #expect(again.domainSuffix == "dev.test")
    }

    // MARK: Apply

    @Test func applyingWritesOnePromptStartsTheServerAndAddsTheSuffix() async throws {
        let r = try rig(port: nil)
        r.store.set(25000, forKey: Defaults.Key.domainDNSPort.rawValue)
        await r.model.applySuffix("Colima.Internal")
        #expect(r.runner.calls.count == 1)
        #expect(r.dialogs.value == 1)
        #expect(r.model.domainSuffix == "colima.internal")
        #expect(r.store.string(forKey: Defaults.Key.domainSuffix.rawValue) == "colima.internal")
        #expect(r.dns.zone == "colima.internal" && r.dns.starts == [25000])
        #expect(r.model.domainStatus.dns.phase == .running)
        #expect(r.model.activeDomainSuffixes == ["localhost", "colima.internal"])
        #expect(r.model.primaryDomainSuffix == "colima.internal")
    }

    @Test func aNameUnderTheSuffixResolvesToARoute() async throws {
        let r = try rig()
        r.model.updateDomainRoutes(try list())
        await apply(r, "colima.internal")
        let table = r.model.domainRoutes
        #expect(table.resolve(host: "web.shop.colima.internal") == table.resolve(host: "web.shop.localhost"))
        if case .route = table.resolve(host: "web.shop.colima.internal") {} else { Issue.record("no route") }
        #expect(r.model.domainSuffixCaption == "web.shop.colima.internal works on this Mac.")
    }

    @Test func aMissingStoredPortGetsARandomOneFromTheInjectedCheck() async throws {
        let r = try rig(port: nil)
        r.model.dnsPortFree = { $0 % 2 == 0 }
        await apply(r, "colima.internal")
        let port = try #require(r.model.storedDNSPort)
        #expect(ColimaModel.dnsPortRange.contains(port) && port % 2 == 0)
        #expect(r.dns.starts == [UInt16(port)])
    }

    @Test func noFreePortStopsBeforeThePrompt() async throws {
        let r = try rig(port: nil)
        r.model.dnsPortFree = { _ in false }
        await r.model.applySuffix("colima.internal")
        #expect(r.runner.calls.isEmpty && r.dialogs.value == 0)
        #expect(r.model.domainStatus.dns.note == "ColimaBar found no free port for the DNS server.")
    }

    @Test func pickDNSPortUsesTheCheckAndGivesUp() {
        #expect(ColimaModel.pickDNSPort(isFree: { _ in true }) != nil)
        #expect(ColimaModel.pickDNSPort(isFree: { _ in false }) == nil)
        var tries = 0
        _ = ColimaModel.pickDNSPort(isFree: { _ in
            tries += 1
            return false
        })
        #expect(tries == 50)
        #expect(ColimaModel.pickDNSPort(isFree: { (20000..<32768).contains($0) }) != nil)
    }

    @Test func aCancelChangesNothing() async throws {
        let r = try rig()
        r.runner.queue(Shell.Result(status: 1, out: "execution error: User canceled. (-128)"))
        await r.model.applySuffix("colima.internal")
        #expect(r.model.domainSuffix == nil)
        #expect(r.store.object(forKey: Defaults.Key.domainSuffix.rawValue) == nil)
        #expect(r.dns.starts.isEmpty)
        #expect(r.model.domainStatus.dns.phase == .off)
        #expect(r.model.domainStatus.dns.note == "You cancelled the password dialog. Nothing changed.")
    }

    @Test func aForeignFileInTheFolderStopsBeforeThePrompt() async throws {
        let r = try rig()
        try "nameserver 127.0.0.1\nport 5353\n".write(toFile: r.file("test"), atomically: true, encoding: .utf8)
        await r.model.applySuffix("test")
        #expect(r.runner.calls.isEmpty && r.dialogs.value == 0)
        #expect(r.model.domainSuffix == nil)
        #expect(
            r.model.domainStatus.dns.note
                == "The file /etc/resolver/test belongs to another tool. Choose another suffix.")
    }

    @Test func aForeignFileThatAppearsLateGivesTheSameNote() async throws {
        let r = try rig()
        r.runner.queue(Shell.Result(status: 3, out: ""))
        await r.model.applySuffix("dev.test")
        #expect(r.model.domainSuffix == nil)
        #expect(r.model.domainStatus.dns.note?.contains("belongs to another tool") == true)
    }

    @Test func aFailedWriteShowsTheError() async throws {
        let r = try rig()
        r.runner.queue(Shell.Result(status: 1, out: "execution error: nope (1)"))
        await r.model.applySuffix("dev.test")
        #expect(r.model.domainSuffix == nil)
        #expect(
            r.model.domainStatus.dns.note == "ColimaBar could not write the resolver file: execution error: nope (1)")
    }

    @Test func anInvalidOrUnchangedSuffixDoesNothing() async throws {
        let r = try rig(suffix: "colima.internal")
        for bad in ["dev", "com", "foo.local", "", "a_b.test", "colima.internal", "COLIMA.INTERNAL."] {
            await r.model.applySuffix(bad)
        }
        #expect(r.runner.calls.isEmpty)
    }

    @Test func applyNeedsTheMasterSwitch() async throws {
        let r = try rig(domains: false)
        await r.model.applySuffix("dev.test")
        #expect(r.runner.calls.isEmpty)
    }

    @Test func changingTheSuffixAsksOnceAndNamesTheOldFile() async throws {
        let r = try rig(suffix: "colima.internal")
        await r.model.startDNSResponder()
        await r.model.applySuffix("dev.test")
        #expect(r.runner.calls.count == 1 && r.dialogs.value == 1)
        let script = try #require(r.runner.calls.first?.last)
        #expect(script.contains("O='colima.internal'") && script.contains("N='dev.test'"))
        #expect(r.model.domainSuffix == "dev.test")
        #expect(r.model.activeDomainSuffixes == ["localhost", "dev.test"])
        #expect(r.dns.zone == "dev.test")
    }

    @Test func aResolverThatMacOSDoesNotUseYetShowsTheNote() async throws {
        let r = try rig(resolves: false)
        await apply(r, "colima.internal")
        #expect(r.model.domainStatus.dns.phase == .notUsedYet)
        #expect(r.model.domainStatus.dns.caption(suffix: "colima.internal", example: nil)?.contains("yet") == true)
        #expect(r.model.primaryDomainSuffix == "localhost")
        // A later check that works moves to running.
        r.model.resolverCheck = { _ in true }
        await r.model.checkResolver()
        #expect(r.model.domainStatus.dns.phase == .running)
    }

    // MARK: Off, the master switch, launch

    @Test func turningTheSuffixOffRemovesTheFileWithOnePrompt() async throws {
        let r = try rig(suffix: "colima.internal")
        await r.model.startDNSResponder()
        #expect(r.model.domainStatus.dns.phase == .running)
        await r.model.removeSuffix()
        #expect(r.runner.calls.count == 1 && r.dialogs.value == 1)
        let script = try #require(r.runner.calls.first?.last)
        #expect(script.contains("N=''") && script.contains("O='colima.internal'"))
        #expect(r.model.domainSuffix == nil)
        #expect(r.store.object(forKey: Defaults.Key.domainSuffix.rawValue) == nil)
        #expect(r.store.object(forKey: Defaults.Key.domainDNSPort.rawValue) == nil)
        #expect(r.dns.port == nil && r.dns.stops >= 1)
        #expect(r.model.domainStatus.dns == DomainStatus.DNS())
        #expect(r.model.activeDomainSuffixes == ["localhost"])
    }

    @Test func aCancelledRemovalKeepsTheSuffix() async throws {
        let r = try rig(suffix: "colima.internal")
        r.store.set("colima.internal", forKey: Defaults.Key.domainSuffix.rawValue)
        await r.model.startDNSResponder()
        r.runner.queue(Shell.Result(status: 1, out: "User canceled. (-128)"))
        await r.model.removeSuffix()
        #expect(r.model.domainSuffix == "colima.internal")
        #expect(r.store.string(forKey: Defaults.Key.domainSuffix.rawValue) == "colima.internal")
        #expect(r.model.domainStatus.dns.phase == .running)
        #expect(r.model.domainStatus.dns.note == "You cancelled the password dialog. Nothing changed.")
        #expect(r.dns.port == 25000)
    }

    @Test func theMasterSwitchOffStopsTheServerAndKeepsTheFile() async throws {
        let r = try rig(suffix: "colima.internal")
        r.store.set("colima.internal", forKey: Defaults.Key.domainSuffix.rawValue)
        await r.model.startDNSResponder()
        r.model.domainsEnabled = false
        #expect(r.dns.port == nil)
        #expect(r.runner.calls.isEmpty)
        #expect(FileManager.default.fileExists(atPath: r.file("colima.internal")))
        #expect(r.model.domainSuffix == "colima.internal")
        r.model.domainsEnabled = true
        #expect(await waitUntil { r.dns.port == 25000 && r.model.domainStatus.dns.phase == .running })
        #expect(r.runner.calls.isEmpty)
    }

    @Test func aLaunchWithTheSuffixStartsTheServerOnTheStoredPort() async throws {
        let r = try rig(suffix: "colima.internal", port: 26123)
        await r.model.startDNSResponder()
        #expect(r.dns.starts == [26123] && r.dns.zone == "colima.internal")
        #expect(r.model.domainStatus.dns.phase == .running && r.model.domainStatus.dns.port == 26123)
        #expect(r.runner.calls.isEmpty && r.dialogs.value == 0)
    }

    @Test func aLaunchWithoutDomainsStartsNothing() async throws {
        let r = try rig(suffix: "colima.internal", domains: false)
        await r.model.startDNSResponder()
        #expect(r.dns.starts.isEmpty)
    }

    @Test func aMissingFileFailsWithRepairText() async throws {
        let r = try rig(suffix: "colima.internal", file: false)
        await r.model.startDNSResponder()
        #expect(r.model.domainStatus.dns.phase == .failed)
        #expect(
            r.model.domainStatus.dns.problem
                == "The file /etc/resolver/colima.internal is missing or changed. Click Repair to write it again.")
        #expect(r.dns.starts.isEmpty)
    }

    @Test func aChangedFileFailsToo() async throws {
        let r = try rig(suffix: "colima.internal")
        try "nameserver 1.1.1.1\n".write(toFile: r.file("colima.internal"), atomically: true, encoding: .utf8)
        await r.model.startDNSResponder()
        #expect(r.model.domainStatus.dns.phase == .failed)
    }

    @Test func aBusyPortFailsAndRepairPicksANewOne() async throws {
        let r = try rig(suffix: "colima.internal", port: 25000)
        r.dns.startSucceeds = false
        await r.model.startDNSResponder()
        #expect(r.model.domainStatus.dns.problem == "The DNS server could not start on port 25000.")
        r.dns.startSucceeds = true
        r.model.dnsPortFree = { $0 != 25000 }
        // The root shell writes the file with the new port.
        await r.model.repairDNS()
        #expect(r.runner.calls.count == 1 && r.dialogs.value == 1)
        let port = try #require(r.model.storedDNSPort)
        #expect(port != 25000)
        let script = try #require(r.runner.calls.first?.last)
        #expect(script.contains("P=\(port)") && script.contains("N='colima.internal'") && script.contains("O=''"))
        #expect(r.model.domainStatus.dns.phase == .running && r.model.domainStatus.dns.port == UInt16(port))
    }

    @Test func repairNeedsAFailedState() async throws {
        let r = try rig(suffix: "colima.internal")
        await r.model.startDNSResponder()
        await r.model.repairDNS()
        #expect(r.runner.calls.isEmpty)
    }

    @Test func repairRefusesAForeignFile() async throws {
        let r = try rig(suffix: "colima.internal")
        try "x\n".write(toFile: r.file("colima.internal"), atomically: true, encoding: .utf8)
        await r.model.startDNSResponder()
        await r.model.repairDNS()
        #expect(r.runner.calls.isEmpty)
        #expect(r.model.domainStatus.dns.note?.contains("belongs to another tool") == true)
    }

    @Test func aListenerFailureFailsThenTriesAgain() async throws {
        let r = try rig(suffix: "colima.internal")
        await r.model.startDNSResponder()
        r.dns.fail()
        #expect(await waitUntil { r.model.domainStatus.dns.phase == .failed })
        #expect(await waitUntil { r.model.domainStatus.dns.phase == .running })
        #expect(r.dns.starts.count == 2)
    }

    @Test func aWakeRestartsAMissingServer() async throws {
        let r = try rig(suffix: "colima.internal")
        await r.model.startDNSResponder()
        r.model.dnsAfterWake()
        try await Task.sleep(for: .milliseconds(50))
        #expect(r.dns.starts.count == 1)  // it lives: no restart
        r.dns.stop()
        r.model.dnsAfterWake()
        #expect(await waitUntil { r.dns.starts.count == 2 })
    }

    @Test func theDiagnosticsLineHasTheSuffixAndThePort() async throws {
        let r = try rig(suffix: "colima.internal")
        #expect(r.model.domainSuffixStatusText.hasPrefix("colima.internal, DNS port none"))
        await r.model.startDNSResponder()
        #expect(r.model.domainSuffixStatusText == "colima.internal, DNS port 25000, running")
        #expect(try rig().model.domainSuffixStatusText == "not set")
    }

    // MARK: Resolver check, wake, files

    @Test func theResolverIsCheckedAgainWhileMacOSDoesNotUseTheFileYet() async throws {
        let r = try rig()
        r.model.domainTimings.dnsRecheck = [0.02, 0.02, 0.02]
        let lookups = Counter()
        // The third lookup works: the launch check and the first recheck fail.
        r.model.resolverCheck = { _ in
            lookups.add()
            return lookups.value >= 3
        }
        await apply(r, "colima.internal")
        #expect(await waitUntil { r.model.domainStatus.dns.phase == .running })
        #expect(lookups.value == 3)
    }

    @Test func aLaunchChecksTheResolverToo() async throws {
        let r = try rig(suffix: "colima.internal", resolves: false)
        r.model.domainTimings.dnsRecheck = []
        await r.model.startDNSResponder()
        #expect(r.model.domainStatus.dns.phase == .notUsedYet)
        #expect(r.model.primaryDomainSuffix == "localhost")
    }

    @Test func aWakeChecksTheResolverAgain() async throws {
        let r = try rig(suffix: "colima.internal")
        r.model.domainTimings.dnsRecheck = []
        await r.model.startDNSResponder()
        #expect(r.model.domainStatus.dns.phase == .running)
        r.model.resolverCheck = { _ in false }
        r.model.dnsAfterWake()
        #expect(await waitUntil { r.model.domainStatus.dns.phase == .notUsedYet })
        #expect(r.dns.starts.count == 1)  // the server lived: no restart
    }

    @Test func aFileWithAnotherPortThanTheStoredOneFailsWithRepair() async throws {
        let r = try rig(suffix: "colima.internal", port: 25000)
        try ResolverFile.content(port: 25001).write(
            toFile: r.file("colima.internal"), atomically: true, encoding: .utf8)
        await r.model.startDNSResponder()
        #expect(r.model.domainStatus.dns.phase == .failed)
        #expect(r.model.domainStatus.dns.problem?.contains("names another port") == true)
        #expect(r.dns.starts.isEmpty)
        // Repair writes a file with the new port (the fake root shell does it).
        await r.model.repairDNS()
        #expect(r.model.domainStatus.dns.phase == .running)
    }

    @Test func changingTheSuffixWorksWhenTheOldFileIsMissingOrForeign() async throws {
        let missing = try rig(suffix: "colima.internal", file: false)
        await missing.model.applySuffix("dev.test")
        #expect(missing.runner.calls.count == 1 && missing.model.domainSuffix == "dev.test")
        let foreign = try rig(suffix: "colima.internal")
        try "nameserver 1.1.1.1\n".write(toFile: foreign.file("colima.internal"), atomically: true, encoding: .utf8)
        await foreign.model.applySuffix("dev.test")
        #expect(foreign.runner.calls.count == 1 && foreign.model.domainSuffix == "dev.test")
        // The root shell leaves a foreign old file alone (`ResolverFileTests`).
    }

    @Test func aFailedRemovalKeepsTheSuffixAndShowsTheError() async throws {
        let r = try rig(suffix: "colima.internal")
        await r.model.startDNSResponder()
        r.runner.queue(Shell.Result(status: 1, out: "execution error: nope (1)"))
        await r.model.removeSuffix()
        #expect(r.model.domainSuffix == "colima.internal")
        #expect(r.model.domainStatus.dns.phase == .running)
        #expect(
            r.model.domainStatus.dns.note == "ColimaBar could not write the resolver file: execution error: nope (1)")
        #expect(r.dns.port == 25000)
    }

    @Test func aForeignFileThatAppearsDuringRepairKeepsTheFailedState() async throws {
        let r = try rig(suffix: "colima.internal", file: false)
        await r.model.startDNSResponder()
        #expect(r.model.domainStatus.dns.phase == .failed)
        r.runner.queue(Shell.Result(status: 3, out: "colimabar-foreign"))
        await r.model.repairDNS()
        #expect(r.model.domainStatus.dns.phase == .failed)
        #expect(r.model.domainStatus.dns.note?.contains("belongs to another tool") == true)
    }

    // MARK: A write that runs

    /// Holds the fake `osascript` until `release()`, like an open password dialog.
    private actor Gate {
        private var waiting: CheckedContinuation<Void, Never>?
        private var open = false
        func wait() async {
            if open { return }
            await withCheckedContinuation { waiting = $0 }
        }
        func release() {
            open = true
            waiting?.resume()
            waiting = nil
        }
    }

    private func gated(_ r: Rig) -> Gate {
        let gate = Gate()
        let inner = r.runner.runner
        r.model.resolverRun = { args in
            await gate.wait()
            return await inner(args)
        }
        return gate
    }

    @Test func aSecondApplyWhileTheDialogShowsDoesNothing() async throws {
        let r = try rig()
        let gate = gated(r)
        let first = Task { await r.model.applySuffix("colima.internal") }
        #expect(await waitUntil { r.model.domainStatus.dns.phase == .applying })
        await r.model.applySuffix("dev.test")
        await r.model.removeSuffix()
        await r.model.repairDNS()
        await gate.release()
        await first.value
        #expect(r.runner.calls.count == 1)
        #expect(r.model.domainSuffix == "colima.internal")
        #expect(r.model.domainStatus.dns.phase == .running)
    }

    @Test func theMasterSwitchDoesNotDisturbAWriteThatRuns() async throws {
        let r = try rig()
        let gate = gated(r)
        let task = Task { await r.model.applySuffix("colima.internal") }
        #expect(await waitUntil { r.model.domainStatus.dns.phase == .applying })
        r.model.domainsEnabled = false
        #expect(r.model.domainStatus.dns.phase == .applying)
        r.model.domainsEnabled = true
        #expect(r.model.domainStatus.dns.phase == .applying)
        r.model.dnsAfterWake()
        try await Task.sleep(for: .milliseconds(30))
        #expect(r.model.domainStatus.dns.phase == .applying && r.dns.starts.isEmpty)
        await gate.release()
        await task.value
        #expect(r.model.domainStatus.dns.phase == .running)
        #expect(r.dns.starts == [25000])
    }

    @Test func aMasterSwitchThatGoesOffDuringAWriteLeavesNoStuckState() async throws {
        let r = try rig()
        let gate = gated(r)
        let task = Task { await r.model.applySuffix("colima.internal") }
        #expect(await waitUntil { r.model.domainStatus.dns.phase == .applying })
        r.model.domainsEnabled = false
        await gate.release()
        await task.value
        // The file is written, the server is off, and the state is not `.applying`.
        #expect(r.model.domainSuffix == "colima.internal")
        #expect(r.model.domainStatus.dns == DomainStatus.DNS())
        #expect(r.dns.starts.isEmpty)
    }

    @Test func aCancelWhileTheMasterSwitchIsOffShowsTheNoteWithAnOffState() async throws {
        let r = try rig(suffix: "colima.internal")
        await r.model.startDNSResponder()
        let gate = gated(r)
        r.runner.queue(Shell.Result(status: 1, out: "User canceled. (-128)"))
        let task = Task { await r.model.removeSuffix() }
        #expect(await waitUntil { r.model.domainStatus.dns.phase == .applying })
        r.model.domainsEnabled = false
        await gate.release()
        await task.value
        #expect(r.model.domainSuffix == "colima.internal")
        #expect(r.model.domainStatus.dns.phase == .off)
        #expect(r.model.domainStatus.dns.note == "You cancelled the password dialog. Nothing changed.")
    }

    @Test func turningTheSuffixOffWorksWithTheMasterSwitchOff() async throws {
        let r = try rig(suffix: "colima.internal", domains: false)
        await r.model.removeSuffix()
        #expect(r.runner.calls.count == 1 && r.model.domainSuffix == nil)
    }

    // MARK: HTTPS and the CA

    private func httpsRig(suffix: String? = nil) async throws -> Rig {
        let r = try rig(suffix: suffix, https: true, ca: true)
        await r.model.startHTTPS()
        #expect(r.model.domainStatus.https.phase == .running)
        return r
    }

    @Test func aSuffixChangeWithHTTPSOnReplacesTheCAAndLeavesNoOldListener() async throws {
        let r = try await httpsRig(suffix: "colima.internal")
        let old = try #require(r.tls.ca)
        let before = r.tls.events.count
        let stale = Counter()
        // At the first dialog, the listener of the old CA is gone already.
        let proxy = r.proxy
        r.tls.onUninstall { if proxy.httpsPort != nil { stale.add() } }
        await apply(r, "dev.test")
        #expect(stale.value == 0)
        #expect(
            Array(r.tls.events.dropFirst(before)) == [
                "uninstall", "prepare", "install", "identityTest", "selfTest 443",
            ])
        let new = try #require(r.tls.ca)
        #expect(new.der != old.der && Set(new.permitted) == ["localhost", "dev.test"])
        #expect(r.model.tlsCA?.der == new.der)
        #expect(r.model.domainStatus.https.phase == .running)
        #expect(r.model.domainStatus.https.problem == nil)
        // One dialog for the resolver file and one before the CA dialogs.
        #expect(r.dialogs.value == 2)
        #expect(r.model.domainStatus.https.caption == "HTTPS listens on port 443.")
    }

    @Test func aCancelledReplacementKeepsTheOldCAAndNoListenerRuns() async throws {
        let r = try await httpsRig()
        let old = try #require(r.tls.ca)
        r.tls.uninstallOutcome = .cancelled
        await apply(r, "dev.test")
        #expect(r.model.domainSuffix == "dev.test")
        #expect(r.tls.ca?.der == old.der && r.model.httpsEnabled)
        let https = r.model.domainStatus.https
        #expect(https.phase == .untrusted && !https.listening)
        #expect(https.problem?.hasPrefix("ColimaBar did not replace") == true)
        #expect(r.proxy.httpsPort == nil)
        // No HTTPS link: the listener is off, and the HTTPS switch offers Trust Again.
        #expect(r.model.domainURL("web.shop")?.scheme != "https")
        // Trust Again: the user agrees this time.
        r.tls.uninstallOutcome = .done
        r.model.trustCAAgain()
        #expect(await waitUntil { r.model.domainStatus.https.phase == .running })
        #expect(Set(try #require(r.tls.ca).permitted) == ["localhost", "dev.test"])
    }

    @Test func anOldCAThatMacOSDoesNotRemoveIsKept() async throws {
        let r = try await httpsRig()
        let old = try #require(r.tls.ca)
        r.tls.uninstallOutcome = .failed(1)
        await apply(r, "dev.test")
        #expect(r.tls.ca?.der == old.der)
        #expect(r.model.domainStatus.https.phase == .untrusted)
        #expect(r.model.domainStatus.https.problem?.hasPrefix("ColimaBar did not replace") == true)
    }

    @Test func aCancelOfTheNewTrustTurnsHTTPSOffAndRemovesTheFiles() async throws {
        let r = try await httpsRig()
        r.tls.installOutcome = .cancelled
        await apply(r, "dev.test")
        #expect(r.model.domainSuffix == "dev.test")
        #expect(!r.model.httpsEnabled && r.tls.ca == nil)
        #expect(r.model.domainStatus.https.phase == .off)
    }

    @Test func turningTheSuffixOffTightensTheCA() async throws {
        let r = try await httpsRig(suffix: "colima.internal")
        await r.model.removeSuffix()
        let ca = try #require(r.tls.ca)
        #expect(ca.permitted == ["localhost"])
        #expect(r.model.domainStatus.https.phase == .running)
        #expect(r.tls.events.contains("uninstall") && r.tls.events.contains("prepare"))
    }

    @Test func aCancelledTighteningKeepsHTTPSRunningWithTheOldCA() async throws {
        let r = try await httpsRig(suffix: "colima.internal")
        let old = try #require(r.tls.ca)
        r.tls.uninstallOutcome = .cancelled
        await r.model.removeSuffix()
        #expect(r.model.domainSuffix == nil)
        #expect(r.tls.ca?.der == old.der)
        #expect(r.model.domainStatus.https.phase == .running && r.model.domainStatus.https.listening)
    }

    @Test func aCancelledPasswordDialogStartsNoCAFlow() async throws {
        let r = try await httpsRig()
        let before = r.tls.events.count
        r.runner.queue(Shell.Result(status: 1, out: "User canceled. (-128)"))
        await r.model.applySuffix("dev.test")
        #expect(r.model.domainSuffix == nil)
        #expect(r.tls.events.count == before && r.model.domainStatus.https.phase == .running)
    }

    @Test func withoutHTTPSNoCAIsTouched() async throws {
        let r = try rig()
        await apply(r, "dev.test")
        #expect(r.tls.events.isEmpty)
        await r.model.removeSuffix()
        #expect(r.tls.events.isEmpty)
    }

    @Test func withTheMasterSwitchOffNoDialogOfTheCAShows() async throws {
        let r = try rig(suffix: "colima.internal", domains: false, https: true, ca: true)
        await r.model.removeSuffix()
        #expect(r.tls.events.isEmpty && r.dialogs.value == 1)
    }

    @Test func aDebugModelNeverReplacesTheCA() async throws {
        let tls = FakeDomainTLS()
        let model = ColimaModel(
            profile: "suffix-debug2", readOnly: true, domainProxy: FakeDomainProxy(), domainsEnabled: true,
            domainsStore: TestProcess.emptyStore(), httpsEnabled: true, domainTLS: tls)
        await model.replaceCAForSuffixes()
        #expect(tls.events.isEmpty)
    }

    @Test func aCAThatMissesTheSuffixAtStartStopsTheListener() async throws {
        let r = try rig(suffix: "colima.internal", https: true, ca: false)
        r.tls.ca = try LocalCA.create(permitted: ["localhost"])
        await r.model.startHTTPS()
        #expect(r.model.domainStatus.https.phase == .untrusted)
        #expect(r.model.domainStatus.https.problem == ColimaModel.needsNewCAText)
        #expect(r.proxy.httpsStarts.isEmpty)
    }

    @Test func httpsLinksUseTheSuffixOnlyWhenTheCACoversIt() async throws {
        let r = try await httpsRig(suffix: "colima.internal")
        await r.model.startDNSResponder()
        #expect(r.model.domainStatus.dns.phase == .running)
        #expect(r.model.primaryDomainSuffix == "colima.internal")
        #expect(r.model.domainURL("web.shop")?.host == "web.shop.colima.internal")
        #expect(r.model.domainURL("web.shop")?.scheme == "https")
        // A CA without the suffix: the link keeps a name that the CA covers.
        r.model.tlsCA = try LocalCA.create(permitted: ["localhost"])
        #expect(r.model.primaryDomainSuffix == "localhost")
        #expect(r.model.domainURL("web.shop")?.host == "web.shop.localhost")
    }

    // MARK: Dashboard after a dialog

    @Test func applyingBringsTheDashboardBackAfterThePasswordDialog() async throws {
        let r = try rig(dashboardOpen: true)
        await r.model.applySuffix("dev.test")
        #expect(r.dialogs.value == 1 && r.restores.value == 1)
        // A cancelled dialog restores it too.
        let c = try rig(dashboardOpen: true)
        c.runner.queue(Shell.Result(status: 1, out: "User canceled. (-128)"))
        await c.model.applySuffix("dev.test")
        #expect(c.dialogs.value == 1 && c.restores.value == 1)
        // A dashboard that was closed stays closed.
        let closed = try rig()
        await closed.model.applySuffix("dev.test")
        #expect(closed.restores.value == 0)
    }

    @Test func removingAndRepairingBringTheDashboardBack() async throws {
        let r = try rig(suffix: "colima.internal", dashboardOpen: true)
        await r.model.removeSuffix()
        #expect(r.restores.value == 1)
        let f = try rig(suffix: "colima.internal", dashboardOpen: true)
        f.model.setDNSStatus(DomainStatus.DNS(phase: .failed, problem: "x"))
        await f.model.repairDNS()
        #expect(f.dialogs.value == 1 && f.restores.value == 1)
        let failed = try rig(suffix: "colima.internal", dashboardOpen: true)
        failed.runner.queue(Shell.Result(status: 1, out: "boom"))
        await failed.model.removeSuffix()
        #expect(failed.restores.value == 1)
    }

    @Test func aSuffixChangeWithHTTPSOnClosesAndRestoresTheDashboardOnce() async throws {
        let r = try rig(suffix: "colima.internal", https: true, ca: true, dashboardOpen: true)
        await r.model.startHTTPS()
        await r.model.applySuffix("dev.test")
        #expect(r.dialogs.value == 1 && r.restores.value == 1)
        #expect(r.model.domainStatus.https.phase == .running)
        // A cancelled replacement restores it too.
        let c = try rig(suffix: "colima.internal", https: true, ca: true, dashboardOpen: true)
        await c.model.startHTTPS()
        c.tls.uninstallOutcome = .cancelled
        await c.model.removeSuffix()
        #expect(c.dialogs.value == 1 && c.restores.value == 1)
        // No replacement is needed: the dashboard still comes back.
        let same = try rig(https: true, ca: true, dashboardOpen: true)
        await same.model.startHTTPS()
        await same.model.replaceCAForSuffixes(reopening: true)
        #expect(same.restores.value == 1 && same.dialogs.value == 0)
    }

    // MARK: A CA that is wider than the names

    @Test func aCancelledTighteningOffersAReplacementAndNamesTheOldCA() async throws {
        let r = try await httpsRig(suffix: "colima.internal")
        r.tls.uninstallOutcome = .cancelled
        await r.model.removeSuffix()
        #expect(r.model.domainStatus.https.widerCA)
        #expect(r.model.caIsWiderThanNeeded)
        // The user clicks Replace and agrees this time.
        r.tls.uninstallOutcome = .done
        await r.model.replaceCAForSuffixes()
        #expect(!r.model.domainStatus.https.widerCA)
        #expect(r.tls.ca?.permitted == ["localhost"])
        #expect(r.model.domainStatus.https.phase == .running)
    }

    @Test func theNoteOfAKeptOldCAHoldsNoFalseClaim() async throws {
        // The old CA covers the names, so the note must not say it does not.
        let r = try await httpsRig(suffix: "colima.internal")
        r.tls.uninstallOutcome = .failed(1)
        await r.model.removeSuffix()
        let https = r.model.domainStatus.https
        #expect(https.phase == .running || https.phase == .untrusted)
        let stillWider = r.model.domainStatus.https.widerCA
        #expect(stillWider)
        // A narrower CA keeps the text that asks for a new one.
        let n = try await httpsRig()
        n.tls.uninstallOutcome = .failed(1)
        await n.model.applySuffix("dev.test")
        #expect(n.model.domainStatus.https.problem?.hasSuffix(ColimaModel.needsNewCAText) == true)
        let text = try #require(n.model.domainStatus.https.problem)
        #expect(!text.contains(ColimaModel.keptOldCAText))
    }

    @Test func aWiderCAWithTheMasterSwitchOffWaitsForTheSwitchAndThenIsReplaced() async throws {
        let r = try rig(suffix: nil, domains: false, https: true, ca: false)
        r.tls.ca = try LocalCA.create(permitted: ["localhost", "gone.test"])
        await r.model.removeSuffix()
        #expect(r.tls.events.isEmpty)
        r.model.domainsEnabled = true
        #expect(await waitUntil { r.tls.ca?.permitted == ["localhost"] })
        #expect(await waitUntil { r.model.domainStatus.https.phase == .running })
        #expect(!r.model.domainStatus.https.widerCA)
    }

    @Test func aReplacementNeedsTheMasterSwitchAndAnExactCA() async throws {
        let r = try rig(domains: false, https: true, ca: true)
        await r.model.replaceCAForSuffixes()
        #expect(r.tls.events.isEmpty)
        let exact = try await httpsRig()
        #expect(!exact.model.caIsWiderThanNeeded && !exact.model.domainStatus.https.widerCA)
        let before = exact.tls.events.count
        await exact.model.replaceCAForSuffixes()
        #expect(exact.tls.events.count == before)
    }

    // MARK: The server after a cancel

    @Test func aCancelledPromptLeavesTheServerRunning() async throws {
        let r = try rig(suffix: "colima.internal")
        await r.model.startDNSResponder()
        #expect(r.dns.port != nil)
        r.runner.queue(Shell.Result(status: 1, out: "User canceled. (-128)"))
        await r.model.applySuffix("dev.test")
        #expect(r.model.domainSuffix == "colima.internal" && r.dns.port != nil)
        // The server was not running (the start waited for the write): the cancel starts it.
        let s = try rig(suffix: "colima.internal")
        #expect(s.dns.port == nil)
        s.runner.queue(Shell.Result(status: 1, out: "User canceled. (-128)"))
        await s.model.removeSuffix()
        #expect(s.dns.port != nil)
        #expect(s.model.domainStatus.dns.phase == .running)
        #expect(s.model.domainStatus.dns.note?.hasPrefix("You cancelled") == true)
    }
}
