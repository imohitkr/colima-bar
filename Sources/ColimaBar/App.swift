import AppKit
import OSLog
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
    private var windowCounted = false          // dashboard window counted in model.visibleCount
    private var appliedHidden: Bool?           // last icon visibility we set
    private var sigterm: DispatchSourceSignal?
    private let log = Logger(subsystem: "com.imohitkr.ColimaBar", category: "app")

    /// launchd sets XPC_SERVICE_NAME to the job label for the login agent.
    static let isLaunchAgent = ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"] == LoginItem.label

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
        Notifier.shared.onContainerAction = { [weak self] action, id, name, profile in
            guard let self else { return }
            // The alert may come from another profile than the one shown now.
            let p = profile ?? self.model.profile
            if Notifier.isRestart(action) {
                self.model.container(id, "restart", profile: p)
            } else {
                self.model.openLogs(id: id, name: name, profile: p)
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

        if !Self.isDebugRun { ensureSingleSupervisedInstance() }
        installMainMenu()
        handleSIGTERM()

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
            Updater.shared.start()
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

    /// One instance only, and when launch at login is on, the one running is
    /// the launchd agent (KeepAlive relaunches it after a crash).
    /// - The agent copy takes over from a copy started by hand.
    /// - A copy started by hand while the agent is enabled asks launchd to
    ///   start the agent instead, then exits.
    /// - Otherwise a second copy sends the running one a reopen event (which
    ///   brings a hidden icon back) and exits.
    private func ensureSingleSupervisedInstance() {
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID)
            .filter { $0 != .current }
        if Self.isLaunchAgent {
            for other in others { other.terminate() }
            let deadline = Date().addingTimeInterval(5)
            while others.contains(where: { !$0.isTerminated }), Date() < deadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            }
            for other in others where !other.isTerminated { other.forceTerminate() }
            return
        }
        if let other = others.first {
            if let url = other.bundleURL {
                // openApplication on a running app delivers a reopen event.
                NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
            } else {
                other.activate()
            }
            // Give the open request time to be sent before exiting.
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
            exit(0)
        }
        guard LoginItem.isEnabled else { return }
        LoginItem.refreshIfNeeded()
        // Hand over only once the agent is seen running; if launchd refuses to
        // start it, carry on as a normal instance so the proxy still runs.
        if LoginItem.kickstart() {
            let deadline = Date().addingTimeInterval(5)
            while Date() < deadline {
                let agentUp = NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID)
                    .contains { $0 != .current && !$0.isTerminated }
                if agentUp { exit(0) }
                RunLoop.current.run(until: Date().addingTimeInterval(0.2))
            }
            log.error("login agent didn't start; running unsupervised")
        }
    }

    /// Accessory apps show no menu bar, but key equivalents still route
    /// through the main menu: without it ⌘C/⌘V/⌘A/⌘W do nothing.
    private func installMainMenu() {
        let main = NSMenu()
        func submenu(_ title: String, _ items: [NSMenuItem]) {
            let m = NSMenu(title: title)
            items.forEach { m.addItem($0) }
            let holder = NSMenuItem()
            holder.submenu = m
            main.addItem(holder)
        }
        // No ⌘Q: quitting stops the auto-start proxy until the next login, so
        // it is only in the right-click menu and the footer, never a reflex.
        submenu("ColimaBar", [NSMenuItem(title: "Quit ColimaBar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")])
        let redo = NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        submenu("Edit", [
            NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"), redo, .separator(),
            NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"),
            NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"),
            NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"),
            NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"),
        ])
        submenu("Window", [
            NSMenuItem(title: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"),
        ])
        NSApp.mainMenu = main
    }

    /// launchd stops the agent with SIGTERM (logout, `launchctl bootout`,
    /// an update). Quit normally so the proxy socket is handed back.
    private func handleSIGTERM() {
        signal(SIGTERM, SIG_IGN)
        let src = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        src.setEventHandler { NSApp.terminate(nil) }
        src.resume()
        sigterm = src
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
            // Write isVisible only when our decision changes, so the system
            // (or the user) hiding the item isn't undone on every refresh.
            let hide = model.iconHidden
            if appliedHidden != hide {
                appliedHidden = hide
                item.isVisible = !hide
                log.notice("menu bar icon \(hide ? "hidden" : "shown", privacy: .public)")
                if hide { model.noteIconHiddenOnce() }
            }
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
        let hide = NSMenuItem(title: "Hide Icon While Colima Is Stopped", action: #selector(toggleHideIcon), keyEquivalent: "")
        hide.target = self
        hide.state = model.hideIconWhenStopped ? .on : .off
        menu.addItem(hide)
        menu.addItem(.separator())
        let ver = NSMenuItem(title: "ColimaBar \(Self.version)", action: nil, keyEquivalent: "")
        ver.isEnabled = false
        menu.addItem(ver)
        if let r = Updater.shared.available {
            add("Download ColimaBar \(r.version)…", #selector(openUpdate))
        } else {
            add("Check for Updates…", #selector(checkUpdates))
        }
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
    @objc private func toggleHideIcon() { model.hideIconWhenStopped.toggle() }
    @objc private func checkUpdates() { Task { await Updater.shared.check(manual: true) } }
    @objc private func openUpdate() { Updater.shared.openReleasePage() }
    @objc private func toggleLogin() {
        do { try LoginItem.set(!LoginItem.isEnabled) } catch {
            model.notify("Login item change failed: \(error.localizedDescription)")
        }
    }

    func applicationWillTerminate(_ note: Notification) {
        // macOS persists isVisible per status item; don't start hidden next time.
        item?.isVisible = true
        if !Self.isDebugRun { model.shutdown() }
    }

    /// Opening the app again (Spotlight, Finder, `open -a ColimaBar`) brings a
    /// hidden icon back and opens the dashboard so Colima can be started.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard item != nil else { return false }
        // Only override the option while the icon is actually hidden;
        // otherwise the next stop would leave it visible.
        if model.iconHidden { model.revealIcon = true }
        appliedHidden = false
        item.isVisible = true
        // macOS places a just-shown status item asynchronously; anchor the
        // popover once it is on screen, or fall back to the window.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self, !self.popover.isShown else { return }
            if let w = self.item.button?.window, w.screen != nil, w.isVisible,
               w.occlusionState.contains(.visible) {
                self.togglePopover()
            } else {
                self.showWindow()
            }
        }
        return false
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
        if !w.isVisible, !w.isMiniaturized { w.center() }
        setWindowCounted(true)
        NSApp.activate()
        w.makeKeyAndOrderFront(nil)
    }

    /// Counts the window in visibleCount exactly once while it is open and not
    /// minimized, however it was opened, minimized or closed.
    private func setWindowCounted(_ on: Bool) {
        guard windowCounted != on else { return }
        windowCounted = on
        model.visibleCount += on ? 1 : -1
    }

    func windowWillClose(_ n: Notification) { setWindowCounted(false) }
    func windowDidMiniaturize(_ n: Notification) { setWindowCounted(false) }
    func windowDidDeminiaturize(_ n: Notification) { setWindowCounted(true) }
}
