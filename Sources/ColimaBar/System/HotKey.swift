import Carbon.HIToolbox
import Foundation
import Observation
import os

/// The global keyboard shortcut that opens and closes the dashboard. It uses
/// Carbon `RegisterEventHotKey`. That call needs no permission. It takes
/// the key exclusively, so macOS refuses a key that another process holds.
/// Only the live copy of the app registers it (see `AppDelegate`). A debug
/// run and the command never register it.
@MainActor @Observable
final class HotKey {
    static let shared = HotKey()
    /// The signature of the hot key ID: "CBar".
    nonisolated static let signature: OSType = 0x4342_6172
    nonisolated private static let log = Logger(category: "hotkey")

    typealias Problem = KeyCombo.Problem

    /// The shortcut in use or wanted, or nil for none.
    private(set) var combo: KeyCombo?
    /// Why the stored shortcut does not work now, or nil.
    private(set) var problem: Problem?
    /// What a press does. AppDelegate sets it.
    @ObservationIgnored var onPress: @MainActor () -> Void = {}

    @ObservationIgnored private let backend: HotKeyBackend
    /// The seconds to wait before each new try at launch.
    @ObservationIgnored private let retryDelays: [Int]
    @ObservationIgnored private var handlerInstalled = false
    @ObservationIgnored private var registered = false
    @ObservationIgnored private var isDebug = false
    @ObservationIgnored private var paused = false

    /// True while macOS delivers the shortcut to the app.
    var isActive: Bool { registered }

    init(backend: HotKeyBackend = .live, retryDelays: [Int] = [1, 3]) {
        self.backend = backend
        self.retryDelays = retryDelays
    }

    // MARK: - Life cycle

    /// Reads the stored shortcut. A normal run also registers it. At launch,
    /// an older copy can still hold the key during a handover, so a refused
    /// key is tried again after the delays in `retryDelays`. A stored value
    /// that ColimaBar cannot use is kept, but never registered.
    func start(debug: Bool) {
        isDebug = debug
        problem = nil
        combo = nil
        guard let spec = backend.read(), !spec.isEmpty else { return }
        guard let stored = KeyCombo(spec: spec) else {
            Self.log.notice("the stored shortcut is not valid and is ignored")
            return
        }
        combo = stored
        guard !debug else { return }
        if let unusable = stored.problem ?? (stored.isReserved(in: backend.symbolicEntries()) ? .system : nil) {
            problem = unusable
            Self.log.notice("the stored shortcut is not used: \(unusable.message, privacy: .public)")
            return
        }
        register()
        guard problem == .inUse else { return }
        for (index, seconds) in retryDelays.enumerated() {
            let isLast = index == retryDelays.count - 1
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(seconds))
                guard let self, self.problem == .inUse, !self.paused, !self.registered else { return }
                self.register(logFailure: isLast)
            }
        }
    }

    func stop() {
        unregister()
        if handlerInstalled {
            backend.removeHandler()
            handlerInstalled = false
        }
    }

    // MARK: - Change

    /// Uses `new` as the shortcut and saves it, or removes it for nil. It
    /// returns the problem and changes nothing if the shortcut does not work.
    func set(_ new: KeyCombo?) -> Problem? {
        guard !isDebug else { return nil }
        if let new {
            if let p = new.problem { return p }
            if new.isReserved(in: backend.symbolicEntries()) { return .system }
        }
        if let p = installHandler() { return p }
        unregister()
        if let new, let p = Self.problem(for: backend.register(new)) {
            Self.log.notice("the shortcut did not register: \(p.message, privacy: .public)")
            if !paused, combo != nil { register() }
            return p
        }
        registered = new != nil
        combo = new
        problem = nil
        paused = false
        backend.write(new?.spec)
        Self.log.notice("the shortcut is \(new == nil ? "off" : "on", privacy: .public)")
        return nil
    }

    /// The recorder pauses the shortcut, so that the keys reach the recorder.
    func pause() {
        guard !isDebug else { return }
        paused = true
        unregister()
    }

    func resume() {
        guard !isDebug, paused else { return }
        paused = false
        register()
    }

    // MARK: - Carbon

    nonisolated static func problem(for status: OSStatus) -> Problem? {
        switch status {
        case noErr: nil
        case OSStatus(eventHotKeyExistsErr): .inUse
        default: .failed(status)
        }
    }

    /// Registers the current combo and sets `problem`. `logFailure` is false
    /// for a try at launch that another try follows.
    private func register(logFailure: Bool = true) {
        guard let combo, !registered else { return }
        if let p = installHandler() {
            problem = p
            return
        }
        problem = Self.problem(for: backend.register(combo))
        registered = problem == nil
        if let problem {
            if logFailure { Self.log.notice("the shortcut did not register: \(problem.message, privacy: .public)") }
        } else {
            Self.log.notice("the shortcut is registered")
        }
    }

    private func unregister() {
        if registered { backend.unregister() }
        registered = false
    }

    /// Installs the press handler once. It returns the problem if that fails.
    private func installHandler() -> Problem? {
        guard !handlerInstalled else { return nil }
        let status = backend.installHandler()
        guard status == noErr else {
            Self.log.error("the shortcut handler did not install (error \(status))")
            return .failed(status)
        }
        handlerInstalled = true
        return nil
    }

    func pressed() {
        guard !paused, !isDebug else { return }
        onPress()
    }
}
