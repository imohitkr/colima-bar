import Foundation
import Security

@testable import ColimaBar

/// Stands in for the disk, the login keychain and the TLS stack of HTTPS. It
/// makes a real CA in memory, but writes no file and changes no keychain or
/// trust setting. A test sets the outcome of each dialog and reads `events`.
/// `@unchecked Sendable`: `lock` guards the state.
final class FakeDomainTLS: DomainTLSServicing, @unchecked Sendable {
    private let lock = NSLock()
    private var saved: LocalCA?
    private var eventLog: [String] = []
    private var selfTests: [Bool] = []
    private var selfTestSuffixLists: [[String]] = []
    private var settings = Settings()
    private var installHook: (@Sendable () -> Void)?
    private var uninstallHook: (@Sendable () -> Void)?

    private struct Settings {
        var install = TrustStore.Outcome.done
        var uninstall = TrustStore.Outcome.done
        var leftovers = TrustStore.Outcome.done
        var trusted = true
        /// nil: the trust settings follow `trusted`.
        var hasSettings: Bool?
        var identitiesWork = true
    }

    let certificatePath = ""

    /// The calls so far, in order.
    var events: [String] { lock.withLock { eventLog } }
    var ca: LocalCA? {
        get { lock.withLock { saved } }
        set { lock.withLock { saved = newValue } }
    }
    var installOutcome: TrustStore.Outcome {
        get { lock.withLock { settings.install } }
        set { lock.withLock { settings.install = newValue } }
    }
    var uninstallOutcome: TrustStore.Outcome {
        get { lock.withLock { settings.uninstall } }
        set { lock.withLock { settings.uninstall = newValue } }
    }
    var leftoversOutcome: TrustStore.Outcome {
        get { lock.withLock { settings.leftovers } }
        set { lock.withLock { settings.leftovers = newValue } }
    }
    /// The suffixes of each self-test, in order.
    var selfTestSuffixes: [[String]] { lock.withLock { selfTestSuffixLists } }
    var trusted: Bool {
        get { lock.withLock { settings.trusted } }
        set { lock.withLock { settings.trusted = newValue } }
    }
    /// Whether the trust settings hold an entry for the CA. Follows `trusted` until a test sets it.
    var hasSettings: Bool {
        get { lock.withLock { settings.hasSettings ?? settings.trusted } }
        set { lock.withLock { settings.hasSettings = newValue } }
    }
    var identitiesWork: Bool {
        get { lock.withLock { settings.identitiesWork } }
        set { lock.withLock { settings.identitiesWork = newValue } }
    }
    /// The results of the next self-tests. When the list is empty, a self-test passes.
    func queueSelfTests(_ results: [Bool]) { lock.withLock { selfTests = results } }
    /// Runs inside `install`, while the real dialog would show.
    func onInstall(_ body: (@Sendable () -> Void)?) { lock.withLock { installHook = body } }
    /// Runs inside `uninstall`, while the real dialog would show.
    func onUninstall(_ body: (@Sendable () -> Void)?) { lock.withLock { uninstallHook = body } }

    private func record(_ event: String) { lock.withLock { eventLog.append(event) } }

    func loadCA() -> LocalCA? { ca }

    func prepareCA(permitted: [String]) throws -> LocalCA {
        record("prepare")
        if let existing = ca, Set(existing.permitted) == Set(permitted) { return existing }
        let created = try LocalCA.create(permitted: permitted)
        ca = created
        return created
    }

    func removeCAFiles() {
        record("removeFiles")
        ca = nil
    }

    func install(_ ca: LocalCA) -> TrustStore.Outcome {
        record("install")
        lock.withLock { installHook }?()
        return installOutcome
    }

    func uninstall(_ ca: LocalCA) -> TrustStore.Outcome {
        record("uninstall")
        lock.withLock { uninstallHook }?()
        return uninstallOutcome
    }

    func uninstallLeftovers() -> TrustStore.Outcome {
        record("uninstallLeftovers")
        return leftoversOutcome
    }

    func isTrusted(_ ca: LocalCA) -> Bool { trusted }
    func hasTrustSettings(_ ca: LocalCA) -> Bool { hasSettings }

    func deleteCertificate(_ ca: LocalCA) { record("deleteCertificate") }

    func identitySelfTest(ca: LocalCA) -> Bool {
        record("identityTest")
        return identitiesWork
    }

    func cleanStale() { record("cleanStale") }

    func selfTest(port: UInt16, ca: LocalCA, suffixes: [String]) async -> Bool {
        record("selfTest \(port)")
        return lock.withLock {
            selfTestSuffixLists.append(suffixes)
            return selfTests.isEmpty ? true : selfTests.removeFirst()
        }
    }
}
