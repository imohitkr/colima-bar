import AppKit
import Observation
import ServiceManagement
import SwiftUI

/// Plain NSStatusItem + NSPopover rather than SwiftUI's MenuBarExtra: it tells
/// us exactly when the dashboard is on screen (so stats only stream then),
/// supports a right-click menu, and keeps one hosting view alive so scroll
/// position and UI state survive reopening.
@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate, NSWindowDelegate {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    static let popoverSize = NSSize(width: 480, height: 640)
    static let bundleID = "com.imohitkr.ColimaBar"
    /// Snapshot/debug runs sit beside the real instance and must not touch
    /// the proxy socket, docker routing or login items.
    static let isDebugRun = CommandLine.arguments.contains { ["--snapshot", "--popover", "--notify-test"].contains($0) }
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    private let model = ColimaModel()
    private let ui = ViewState()
    private var item: NSStatusItem!
    private let popover = NSPopover()
    private var window: NSWindow?

    func applicationWillFinishLaunching(_ note: Notification) {
        // Before launch completes, so a notification click that launched us
        // isn't lost.
        Notifier.shared.install()
        Notifier.shared.onAlert = { [weak self] title, body, ctr in
            self?.model.record(title, body, containerID: ctr?.id)
        }
        Notifier.shared.onPermission = { [weak self] ok in
            if self?.model.notificationsAllowed != ok { self?.model.notificationsAllowed = ok }
        }
        Notifier.shared.onContainerAction = { [weak self] action, id, name in
            guard let self else { return }
            if Notifier.isRestart(action) {
                self.model.container(id, "restart")
            } else {
                self.model.openLogs(id: id, name: name)
            }
        }
    }

    func applicationDidFinishLaunching(_ note: Notification) {
        if CommandLine.arguments.contains("--notify-test") {
            Task {
                await Notifier.shared.selfTest()
                try? await Task.sleep(for: .seconds(2))
                exit(0)
            }
            return
        }

        // One instance only: a second launch (Finder, `open`, the login agent)
        // hands over to the running one and exits.
        if !Self.isDebugRun,
           let other = NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID)
            .first(where: { $0 != .current }) {
            other.activate()
            exit(0)
        }

        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.target = self
        item.button?.action = #selector(clicked)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        item.button?.imagePosition = .imageLeading
        item.button?.setAccessibilityLabel("Colima")
        item.button?.setAccessibilityHelp("Left-click for the dashboard, right-click for quick actions")

        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self
        // Fixed size, and the hosting controller must not drive it: if it
        // reports its SwiftUI size after the popover is on screen, the popover
        // grows upward from its anchor and ends up off the top of the screen.
        let host = NSHostingController(rootView:
            DashboardView(model: model, ui: ui, openWindow: { [weak self] in self?.showWindow() }))
        host.sizingOptions = []
        host.view.frame = NSRect(origin: .zero, size: Self.popoverSize)
        popover.contentViewController = host
        popover.contentSize = Self.popoverSize

        model.start(debug: Self.isDebugRun)
        updateIcon()
        if !Self.isDebugRun {
            LoginItem.migrate()
            registerLoginItemOnce()
        }
        if CommandLine.arguments.contains("--window") { showWindow() }
        // Debug: `--popover [PATH]` opens the popover on launch and, with a
        // path, renders it to a PNG and quits.
        if let i = CommandLine.arguments.firstIndex(of: "--popover") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.togglePopover() }
            if i + 1 < CommandLine.arguments.count {
                let path = CommandLine.arguments[i + 1]
                DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
                    if let v = self?.popover.contentViewController?.view { self?.snapshot(v, to: path) }
                    NSApp.terminate(nil)
                }
            }
        }
        // Debug: `--snapshot PATH [TAB]` renders the dashboard window to a PNG
        // a few seconds after launch (no Screen Recording permission needed).
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
            if i + 2 < args.count, let tab = Tab(rawValue: args[i + 2]) { ui.tab = tab }
            if let h = ProcessInfo.processInfo.environment["COLIMABAR_HINT"] { Hint.shared.text = h }
            if let name = ProcessInfo.processInfo.environment["COLIMABAR_LOGS"] {
                // Snapshot the log viewer for a container instead.
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                    guard let self, let c = self.model.containers.first(where: { $0.name == name }) else { return }
                    self.model.openLogs(id: c.id, name: c.name)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
                    if let v = NSApp.windows.first(where: { $0.title.hasPrefix("Logs:") })?.contentView {
                        self?.snapshot(v, to: args[i + 1])
                    }
                    NSApp.terminate(nil)
                }
                return
            }
            showWindow()
            if let hs = ProcessInfo.processInfo.environment["COLIMABAR_SNAPSHOT_HEIGHT"], let h = Double(hs) {
                window?.setContentSize(NSSize(width: 480, height: h))
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
                if let v = self?.window?.contentView { self?.snapshot(v, to: args[i + 1]) }
                NSApp.terminate(nil)
            }
        }
    }

    private func snapshot(_ view: NSView, to path: String) {
        guard let layer = view.layer else { return }
        let scale = view.window?.backingScaleFactor ?? 2
        let w = Int(view.bounds.width * scale), h = Int(view.bounds.height * scale)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            ctx.setFillColor(NSColor.windowBackgroundColor.cgColor)
        }
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.scaleBy(x: scale, y: scale)
        // CALayer.render draws flipped relative to a bitmap context.
        ctx.translateBy(x: 0, y: view.bounds.height)
        ctx.scaleBy(x: 1, y: -1)
        layer.render(in: ctx)
        guard let img = ctx.makeImage() else { return }
        let rep = NSBitmapImageRep(cgImage: img)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }

    // MARK: - Status item

    /// Re-renders the icon whenever the fields it reads change.
    private func updateIcon() {
        withObservationTracking {
            let symbol: String
            var title = ""
            if model.busy != nil {
                symbol = "hourglass"
            } else if model.state != .running {
                symbol = "shippingbox"
            } else {
                symbol = model.unhealthyCount > 0 ? "exclamationmark.triangle.fill" : "shippingbox.fill"
                let n = model.running.count
                if n > 0 { title = " \(n)" }
            }
            let img = NSImage(systemSymbolName: symbol, accessibilityDescription: "Colima")
            img?.isTemplate = true
            item.button?.image = img
            item.button?.title = title
            item.button?.setAccessibilityValue(model.busy ?? (model.state == .running
                ? "\(model.running.count) containers running" : "stopped"))
            item.button?.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        } onChange: {
            // The app delegate lives for the whole process.
            Task { @MainActor in self.updateIcon() }
        }
    }

    @objc private func clicked() {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp || event.modifierFlags.contains(.control) {
            showMenu()
        } else {
            togglePopover()
        }
    }

    private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
        } else if let button = item.button {
            NSApp.activate()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    private func showMenu() {
        let menu = NSMenu()
        func add(_ title: String, _ sel: Selector, key: String = "") {
            let i = NSMenuItem(title: title, action: sel, keyEquivalent: key)
            i.target = self
            menu.addItem(i)
        }
        if model.state == .running {
            add("Restart Colima", #selector(restartVM))
            add("Stop Colima", #selector(stopVM))
        } else {
            add("Start Colima", #selector(startVM))
        }
        menu.addItem(.separator())
        add("Open Dashboard Window", #selector(openWindowAction))
        let login = NSMenuItem(title: "Launch at Login", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        login.state = LoginItem.isEnabled ? .on : .off
        menu.addItem(login)
        let auto = NSMenuItem(title: "Auto-start Colima on Demand", action: #selector(toggleAutoStart), keyEquivalent: "")
        auto.target = self
        auto.state = model.autoStart ? .on : .off
        menu.addItem(auto)
        menu.addItem(.separator())
        let ver = NSMenuItem(title: "ColimaBar \(Self.version)", action: nil, keyEquivalent: "")
        ver.isEnabled = false
        menu.addItem(ver)
        add("Quit ColimaBar", #selector(quit), key: "q")
        item.menu = menu
        item.button?.performClick(nil)
        item.menu = nil   // so the next left click opens the popover again
    }

    /// Turns launch-at-login on the first time the app runs; after that the
    /// user's choice (System tab / right-click menu) is left alone.
    private func registerLoginItemOnce() {
        let key = "didOfferLoginItem"
        guard !UserDefaults.standard.bool(forKey: key),
              Bundle.main.bundlePath.contains("/Applications/") else { return }
        UserDefaults.standard.set(true, forKey: key)
        try? LoginItem.set(true)
    }

    @objc private func startVM() { model.ctl("start") }
    @objc private func stopVM() { model.ctl("stop") }
    @objc private func restartVM() { model.ctl("restart") }
    @objc private func openWindowAction() { showWindow() }
    @objc private func quit() { NSApp.terminate(nil) }
    @objc private func toggleAutoStart() { model.autoStart.toggle() }
    @objc private func toggleLogin() {
        do { try LoginItem.set(!LoginItem.isEnabled) } catch {
            model.notify("Login item change failed: \(error.localizedDescription)")
        }
    }

    func applicationWillTerminate(_ note: Notification) {
        if !Self.isDebugRun { model.shutdown() }
    }

    // MARK: - Visibility drives live stats

    func popoverWillShow(_ n: Notification) {
        model.visibleCount += 1
        Task { await Notifier.shared.refreshPermission() }
    }
    func popoverDidClose(_ n: Notification) { model.visibleCount -= 1 }

    // MARK: - Detached window

    private func showWindow() {
        popover.performClose(nil)
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 760),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable],
                             backing: .buffered, defer: false)
            w.title = "Colima"
            w.isReleasedWhenClosed = false
            w.contentViewController = NSHostingController(rootView:
                DashboardView(model: model, ui: ui, inWindow: true))
            w.setFrameAutosaveName("ColimaBarDashboard")
            w.delegate = self
            window = w
        }
        guard let w = window else { return }
        if !w.isVisible {
            model.visibleCount += 1
            w.center()
        }
        NSApp.activate()
        w.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ n: Notification) {
        model.visibleCount -= 1
    }
}
