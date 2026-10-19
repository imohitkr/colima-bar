import AppKit
import Observation

/// The state of the shortcut recorder. While it records, a local event
/// monitor takes the key presses, and the hot key is paused, so the keys
/// reach the recorder and not the old shortcut.
@MainActor @Observable
final class ShortcutRecording {
    /// What one key event means while recording.
    enum Step: Equatable {
        case cancel
        case ignore
        case combo(KeyCombo)
    }

    private(set) var isRecording = false
    /// The modifiers that the user holds now, as symbols.
    private(set) var held = ""
    /// Why the last key press did not work.
    private(set) var message: String?

    @ObservationIgnored private var monitor: Any?
    @ObservationIgnored private var resign: NSObjectProtocol?

    nonisolated private static let escape: UInt16 = 53

    /// Esc cancels, with any modifiers. A repeat of a held key does nothing.
    nonisolated static func step(keyCode: UInt16, flags: NSEvent.ModifierFlags, isRepeat: Bool) -> Step {
        if keyCode == escape { return .cancel }
        if isRepeat { return .ignore }
        return .combo(KeyCombo(keyCode: keyCode, flags: flags))
    }

    /// The symbols of the modifiers in `flags`, in the order ⌃⌥⇧⌘.
    nonisolated static func symbols(for flags: NSEvent.ModifierFlags) -> String {
        var text = ""
        if flags.contains(.control) { text += "⌃" }
        if flags.contains(.option) { text += "⌥" }
        if flags.contains(.shift) { text += "⇧" }
        if flags.contains(.command) { text += "⌘" }
        return text
    }

    func start() {
        guard !isRecording else { return }
        isRecording = true
        held = ""
        message = nil
        HotKey.shared.pause()
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            let isFlags = event.type == .flagsChanged
            let (code, flags, isRepeat) = (event.keyCode, event.modifierFlags, !isFlags && event.isARepeat)
            MainActor.assumeIsolated {
                self?.handle(flagsOnly: isFlags, keyCode: code, flags: flags, isRepeat: isRepeat)
            }
            return nil
        }
        resign = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: NSApp.keyWindow, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.cancel() }
        }
    }

    func cancel() {
        guard isRecording else { return }
        isRecording = false
        held = ""
        message = nil
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if let resign { NotificationCenter.default.removeObserver(resign) }
        resign = nil
        HotKey.shared.resume()
    }

    func toggle() {
        if isRecording { cancel() } else { start() }
    }

    private func handle(flagsOnly: Bool, keyCode: UInt16, flags: NSEvent.ModifierFlags, isRepeat: Bool) {
        if flagsOnly {
            held = Self.symbols(for: flags)
            return
        }
        switch Self.step(keyCode: keyCode, flags: flags, isRepeat: isRepeat) {
        case .cancel: cancel()
        case .ignore: break
        case .combo(let combo):
            if let problem = combo.problem ?? HotKey.shared.set(combo) {
                message = problem.message
                AccessibilityNotification.Announcement(problem.message).post()
            } else {
                cancel()
            }
        }
    }
}
