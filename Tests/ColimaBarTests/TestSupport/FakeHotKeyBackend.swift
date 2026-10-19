import Carbon.HIToolbox

@testable import ColimaBar

/// A `HotKeyBackend` that records the calls and registers no real hot key.
@MainActor
final class FakeHotKeyBackend {
    var installStatus: OSStatus = noErr
    /// The statuses for the next `register` calls. An empty list means success.
    var registerStatuses: [OSStatus] = []
    var symbolic: [[String: Any]] = []
    var stored: String?
    private(set) var registerCalls: [KeyCombo] = []
    private(set) var installCalls = 0
    private(set) var removeCalls = 0
    private(set) var unregisterCalls = 0

    init(stored: String? = nil) { self.stored = stored }

    var backend: HotKeyBackend {
        HotKeyBackend(
            installHandler: { [self] in
                installCalls += 1
                return installStatus
            },
            removeHandler: { [self] in removeCalls += 1 },
            register: { [self] combo in
                registerCalls.append(combo)
                return registerStatuses.isEmpty ? noErr : registerStatuses.removeFirst()
            },
            unregister: { [self] in unregisterCalls += 1 },
            symbolicEntries: { [self] in symbolic },
            read: { [self] in stored },
            write: { [self] in stored = $0 })
    }

    func hotKey() -> HotKey { HotKey(backend: backend, retryDelays: []) }
}
