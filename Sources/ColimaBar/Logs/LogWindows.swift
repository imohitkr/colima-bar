import AppKit
import SwiftUI

/// One window per container; closing it stops the stream.
@MainActor
final class LogWindows: NSObject, NSWindowDelegate {
    static let shared = LogWindows()
    private var windows: [String: (NSWindow, LogStore)] = [:]

    func open(api: DockerAPI, id: String, name: String, openInTerminal: @escaping () -> Void) {
        if let (w, _) = windows[id] {
            NSApp.activate()
            w.makeKeyAndOrderFront(nil)
            return
        }
        let store = LogStore(api: api, containerID: id, name: name)
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        w.title = "Logs: \(name)"
        w.isReleasedWhenClosed = false
        w.contentViewController = NSHostingController(rootView: LogView(store: store, openInTerminal: openInTerminal))
        w.setFrameAutosaveName("ColimaBarLogs")
        w.delegate = self
        windows[id] = (w, store)
        store.start()
        w.center()
        NSApp.activate()
        w.makeKeyAndOrderFront(nil)
    }

    // A minimized or covered window does no UI work for new lines.
    func windowDidChangeOcclusionState(_ n: Notification) { updateOnScreen(n) }
    func windowDidMiniaturize(_ n: Notification) { updateOnScreen(n) }
    func windowDidDeminiaturize(_ n: Notification) { updateOnScreen(n) }

    private func updateOnScreen(_ n: Notification) {
        guard let w = n.object as? NSWindow,
            let entry = windows.values.first(where: { $0.0 === w })
        else { return }
        entry.1.setOnScreen(!w.isMiniaturized && w.occlusionState.contains(.visible))
    }

    func windowWillClose(_ n: Notification) {
        guard let w = n.object as? NSWindow,
            let (id, entry) = windows.first(where: { $0.value.0 === w })
        else { return }
        entry.1.stop()
        windows[id] = nil
    }
}
