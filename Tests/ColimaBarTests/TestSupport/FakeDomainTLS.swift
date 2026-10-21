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
    private var made: [RecordingProvider] = []
    private var settings = Settings()

    private struct Settings {
        var install = TrustStore.Outcome.done
        var uninstall = TrustStore.Outcome.done
        var trusted = true
        var providerWorks = true
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
    var trusted: Bool {
        get { lock.withLock { settings.trusted } }
        set { lock.withLock { settings.trusted = newValue } }
    }
    var providerWorks: Bool {
        get { lock.withLock { settings.providerWorks } }
        set { lock.withLock { settings.providerWorks = newValue } }
    }
    /// The results of the next self-tests. When the list is empty, a self-test passes.
    func queueSelfTests(_ results: [Bool]) { lock.withLock { selfTests = results } }
    var providers: [RecordingProvider] { lock.withLock { made } }

    private func record(_ event: String) { lock.withLock { eventLog.append(event) } }

    func loadCA() -> LocalCA? { ca }

    func prepareCA(permitted: [String]) throws -> LocalCA {
        record("prepare")
        if let existing = ca { return existing }
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
        return installOutcome
    }

    func uninstall(_ ca: LocalCA) -> TrustStore.Outcome {
        record("uninstall")
        return uninstallOutcome
    }

    func isTrusted(_ ca: LocalCA) -> Bool { trusted }

    func makeProvider(ca: LocalCA) -> TLSIdentityProvider? {
        record("makeProvider")
        guard providerWorks else { return nil }
        let provider = RecordingProvider()
        lock.withLock { made.append(provider) }
        return provider
    }

    func cleanStale() { record("cleanStale") }

    func selfTest(port: UInt16, ca: LocalCA) async -> Bool {
        record("selfTest \(port)")
        return lock.withLock { selfTests.isEmpty ? true : selfTests.removeFirst() }
    }

    /// An identity provider in memory that counts its calls.
    final class RecordingProvider: TLSIdentityProvider, @unchecked Sendable {
        private let inner = PrivateIdentityProvider()
        private let lock = NSLock()
        private var removals = 0
        private var unlocks = 0
        let name = "recording"
        var removeCount: Int { lock.withLock { removals } }
        var unlockCount: Int { lock.withLock { unlocks } }
        func identity(certificate: SecCertificate, key: SecKey) throws -> SecIdentity {
            try inner.identity(certificate: certificate, key: key)
        }
        func unlockIfNeeded() { lock.withLock { unlocks += 1 } }
        func removeAll() { lock.withLock { removals += 1 } }
    }
}
