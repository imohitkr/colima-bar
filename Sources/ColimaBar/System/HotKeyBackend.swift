import Carbon.HIToolbox
import Foundation

/// The calls that `HotKey` makes to Carbon and to the saved settings. A test
/// gives fakes, so that it never registers a real hot key.
@MainActor
struct HotKeyBackend {
    /// Installs the press handler. It returns the status.
    var installHandler: () -> OSStatus
    var removeHandler: () -> Void
    /// Registers one key. It returns the status.
    var register: (KeyCombo) -> OSStatus
    var unregister: () -> Void
    /// The symbolic hot keys of macOS (see `KeyCombo.isReserved`).
    var symbolicEntries: () -> [[String: Any]]
    /// The saved spec.
    var read: () -> String?
    /// Saves the spec, or removes it for nil.
    var write: (String?) -> Void

    static var live: HotKeyBackend {
        let carbon = LiveCarbon()
        return HotKeyBackend(
            installHandler: { carbon.installHandler() },
            removeHandler: { carbon.removeHandler() },
            register: { carbon.register($0) },
            unregister: { carbon.unregister() },
            symbolicEntries: {
                var list: Unmanaged<CFArray>?
                guard CopySymbolicHotKeys(&list) == noErr, let list else { return [] }
                return list.takeRetainedValue() as? [[String: Any]] ?? []
            },
            read: { Defaults.string(.hotKey) },
            write: { if let spec = $0 { Defaults.set(spec, .hotKey) } else { Defaults.remove(.hotKey) } })
    }
}

/// The real Carbon calls and the references they give.
@MainActor
private final class LiveCarbon {
    private static let identifier: UInt32 = 1
    private var handler: EventHandlerRef?
    private var key: EventHotKeyRef?

    func installHandler() -> OSStatus {
        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        return InstallEventHandler(GetApplicationEventTarget(), hotKeyEvent, 1, &spec, nil, &handler)
    }

    func removeHandler() {
        if let handler { RemoveEventHandler(handler) }
        handler = nil
    }

    func register(_ combo: KeyCombo) -> OSStatus {
        let id = EventHotKeyID(signature: HotKey.signature, id: Self.identifier)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            combo.keyCode, combo.modifiers, id, GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive), &ref)
        key = status == noErr ? ref : nil
        return status
    }

    func unregister() {
        if let key { UnregisterEventHotKey(key) }
        key = nil
    }
}

/// Carbon calls this on the main thread. The work runs after it returns.
private func hotKeyEvent(_: EventHandlerCallRef?, _ event: EventRef?, _: UnsafeMutableRawPointer?) -> OSStatus {
    var id = EventHotKeyID()
    let status = GetEventParameter(
        event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
        MemoryLayout<EventHotKeyID>.size, nil, &id)
    guard status == noErr, id.signature == HotKey.signature else { return OSStatus(eventNotHandledErr) }
    DispatchQueue.main.async { MainActor.assumeIsolated { HotKey.shared.pressed() } }
    return noErr
}
