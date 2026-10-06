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
    static let isDebugRun = CommandLine.arguments.contains {
        ["--snapshot", "--popover", "--notify-test"].contains($0)
    }
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    private let model = ColimaModel()
    private let ui = ViewState()
    private var item: NSStatusItem!
    private let popover = NSPopover()
    private var window: NSWindow?
    private var windowCounted = false  // dashboard window counted in model.visibleCount
    private var appliedHidden: Bool?  // last icon visibility we set
    private var sigterm: DispatchSourceSignal?
    private let log = Logger(subsystem: "com.imohitkr.ColimaBar", category: "app")

    /// launchd sets XPC_SERVICE_NAME to the job label for the login agent.
    static let isLaunchAgent = ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"] == LoginItem.label
    /// An older copy started this one to replace itself after an update
    /// (see relaunchIfUpdated()).
    static let isReplacement = CommandLine.arguments.contains("--replace")
    private var relaunching = false

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
        // launchd starts apps with a limit of 256 open files. The proxy, stats
        // streams and log windows can need more.
        let files = FileLimit.raise()
        log.info("open file limit: \(files)")
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
        let host = NSHostingController(
            rootView:
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
        // An older copy restarted into this one after an update while the
        // user opened the app (see relaunchIfUpdated()). Do what the reopen
        // would have done. Read the request in every case, so it is used once.
        if !Self.isDebugRun, Self.takeRevealRequest() || CommandLine.arguments.contains("--reveal") {
            model.revealIcon = true
            reveal(after: 1)
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
            // Away from the mouse pointer, so no hover hint shows up in the shot.
            window?.setFrameOrigin(NSPoint(x: -4000, y: -4000))
            // COLIMABAR_SNAPSHOT_DELAY: wait longer so the sparklines fill up.
            let delay = ProcessInfo.processInfo.environment["COLIMABAR_SNAPSHOT_DELAY"].flatMap(Double.init) ?? 6
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                if let v = self?.window?.contentView { self?.snapshot(v, to: args[i + 1]) }
                NSApp.terminate(nil)
            }
        }
    }

    /// One instance only, and when launch at login is on, the one running is
    /// the launchd agent (KeepAlive relaunches it after a crash).
    /// - The agent copy takes over from a copy started by hand.
    /// - A replacement copy (`--replace`) takes over from the older copy.
    /// - A copy started by hand while the agent is enabled asks launchd to
    ///   start the agent instead, then exits.
    /// - A newer installed copy takes over from an older copy at another
    ///   path (see takesOver).
    /// - Otherwise a second copy sends the running one a reopen event (which
    ///   brings a hidden icon back) and exits.
    private func ensureSingleSupervisedInstance() {
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID)
            .filter { $0 != .current }
        // An update can go to another path: the new copy in /Applications and
        // the old one still running from ~/Applications. A reopen event only
        // reaches the old copy, so this newer copy takes over like `--replace`.
        // A normal quit exits 0, so launchd does not restart an old agent
        // (KeepAlive restarts only on a failed exit). Below, refreshIfNeeded()
        // points the login item at this copy, and kickstart() starts it.
        let takeOver =
            !Self.isLaunchAgent && !Self.isReplacement
            && others.first.map {
                Self.takesOver(
                    mine: Self.version, other: $0.bundleURL.flatMap(Self.onDiskVersion(of:)),
                    installed: LoginItem.isInstalled(Bundle.main.bundlePath))
            } == true
        if takeOver {
            log.notice("a newer copy takes over from \(others.first?.bundleURL?.path ?? "?", privacy: .public)")
        }
        if Self.isLaunchAgent || Self.isReplacement || takeOver {
            // Quitting runs the other copy's shutdown, which frees the proxy
            // socket before this copy starts listening on it.
            for other in others { other.terminate() }
            let deadline = Date().addingTimeInterval(5)
            while others.contains(where: { !$0.isTerminated }), Date() < deadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            }
            for other in others where !other.isTerminated { other.forceTerminate() }
            if Self.isLaunchAgent {
                // Only rewrites an outdated plist; the agent never reloads itself.
                LoginItem.refreshIfNeeded()
                return
            }
        } else if let other = others.first {
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
            for item in items { m.addItem(item) }
            let holder = NSMenuItem()
            holder.submenu = m
            main.addItem(holder)
        }
        // No ⌘Q: quitting stops the auto-start proxy until the next login, so
        // it is only in the right-click menu and the footer, never a reflex.
        submenu(
            "ColimaBar",
            [NSMenuItem(title: "Quit ColimaBar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")])
        let redo = NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        submenu(
            "Edit",
            [
                NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"), redo, .separator(),
                NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"),
                NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"),
                NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"),
                NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"),
            ])
        submenu(
            "Window",
            [
                NSMenuItem(title: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
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
        guard
            let ctx = CGContext(
                data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return }
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
            item.button?.setAccessibilityValue(
                model.busy
                    ?? (model.state == .running
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
        let auto = NSMenuItem(
            title: "Auto-start Colima on Demand", action: #selector(toggleAutoStart), keyEquivalent: "")
        auto.target = self
        auto.state = model.autoStart ? .on : .off
        menu.addItem(auto)
        let hide = NSMenuItem(
            title: "Hide Icon While Colima Is Stopped", action: #selector(toggleHideIcon), keyEquivalent: "")
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
        item.menu = nil  // so the next left click opens the popover again
    }

    /// Turns launch-at-login on the first time the app runs; after that the
    /// user's choice (System tab / right-click menu) is left alone.
    private func registerLoginItemOnce() {
        let key = "didOfferLoginItem"
        guard !UserDefaults.standard.bool(forKey: key),
            Bundle.main.bundlePath.contains("/Applications/")
        else { return }
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
        // A non-zero exit makes launchd start the agent again (KeepAlive).
        if relaunching, Self.isLaunchAgent {
            // exit() skips the normal preference flush; write revealOnLaunch now.
            CFPreferencesAppSynchronize(kCFPreferencesCurrentApplication)
            exit(EX_TEMPFAIL)
        }
    }

    /// CFBundleShortVersionString as it is on disk now. Bundle.main caches
    /// the Info.plist it read at launch.
    nonisolated static func onDiskVersion(of bundle: URL) -> String? {
        let plist = NSDictionary(contentsOf: bundle.appendingPathComponent("Contents/Info.plist"))
        return plist?["CFBundleShortVersionString"] as? String
    }

    /// How a running copy restarts after an update replaced its bundle.
    enum Restart: Equatable {
        case none
        /// Quit with a failed exit, so launchd starts the agent again.
        case agent
        /// Open a new instance with `--replace`, then quit.
        case manual
    }

    /// Any change of the version on disk restarts, a downgrade too.
    nonisolated static func restart(running: String, onDisk: String?, isAgent: Bool) -> Restart {
        guard let onDisk, onDisk != running else { return .none }
        return isAgent ? .agent : .manual
    }

    /// A second copy takes over from the running copy only when it is
    /// installed (not run from a DMG or Downloads) and its version is newer
    /// than the running copy's version on disk.
    nonisolated static func takesOver(mine: String, other: String?, installed: Bool) -> Bool {
        guard installed, let other else { return false }
        return Version.isNewer(mine, than: other)
    }

    /// UserDefaults key: the time (seconds since 1970) when an old copy
    /// restarted into the new version for a reopen. The new copy then
    /// reveals the icon and opens the dashboard.
    nonisolated static let revealKey = "revealOnLaunch"

    /// A reveal request counts for 60 s. An older one is from a restart
    /// that failed or was long ago.
    nonisolated static func revealRequestIsFresh(_ requestedAt: Double?, now: Double) -> Bool {
        guard let requestedAt else { return false }
        let age = now - requestedAt
        return age >= 0 && age < 60
    }

    /// Reads and removes the reveal request.
    private static func takeRevealRequest() -> Bool {
        let at = UserDefaults.standard.object(forKey: revealKey) as? Double
        if at != nil { UserDefaults.standard.removeObject(forKey: revealKey) }
        return revealRequestIsFresh(at, now: Date().timeIntervalSince1970)
    }

    /// An update (DMG, installer) replaces the bundle while this process
    /// runs. Opening the app then only sends a reopen event to this old
    /// process, so the new version never starts. Restart into the new code:
    /// - The agent quits with a non-zero exit, and launchd starts it again.
    /// - A copy started by hand opens a new instance with `--replace`, then
    ///   quits. The new instance waits until this copy has quit (and freed
    ///   the proxy socket) instead of sending it a reopen event.
    /// The new instance reveals the icon and opens the dashboard, as the
    /// reopen asked: `--reveal` for a copy started by hand, and a UserDefaults
    /// request for the agent (launchd starts it without arguments).
    /// Returns true if a restart has begun.
    private func relaunchIfUpdated() -> Bool {
        guard !Self.isDebugRun, !relaunching else { return false }
        let onDisk = Self.onDiskVersion(of: Bundle.main.bundleURL)
        let restart = Self.restart(running: Self.version, onDisk: onDisk, isAgent: Self.isLaunchAgent)
        guard restart != .none else { return false }
        relaunching = true
        log.notice(
            "bundle on disk is \(onDisk ?? "?", privacy: .public), running \(Self.version, privacy: .public); restarting"
        )
        // Also for a copy started by hand: if the agent takes over from the
        // new instance, the agent reads it.
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.revealKey)
        if restart == .agent {
            NSApp.terminate(nil)
            return true
        }
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.createsNewApplicationInstance = true
        cfg.arguments = ["--replace", "--reveal"]
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: cfg) { [weak self] _, error in
            DispatchQueue.main.async {
                guard let self else { return }
                if let error {
                    // Keep this copy running, so the proxy stays up.
                    self.log.error("couldn't start the new version: \(error.localizedDescription, privacy: .public)")
                    self.relaunching = false
                    UserDefaults.standard.removeObject(forKey: Self.revealKey)
                    if self.model.iconHidden { self.model.revealIcon = true }
                    self.reveal()
                    return
                }
                NSApp.terminate(nil)
            }
        }
        return true
    }

    /// Opening the app again (Spotlight, Finder, `open -a ColimaBar`) brings a
    /// hidden icon back and opens the dashboard so Colima can be started.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard item != nil, !relaunchIfUpdated() else { return false }
        // Only override the option while the icon is actually hidden;
        // otherwise the next stop would leave it visible.
        if model.iconHidden { model.revealIcon = true }
        reveal()
        return false
    }

    /// Shows the icon and opens the dashboard: the popover when the icon is
    /// on screen, otherwise the window.
    private func reveal(after delay: Double = 0.25) {
        appliedHidden = false
        item.isVisible = true
        // macOS places a just-shown status item asynchronously; anchor the
        // popover once it is on screen, or fall back to the window.
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, !self.popover.isShown else { return }
            if let w = self.item.button?.window, w.screen != nil, w.isVisible,
                w.occlusionState.contains(.visible)
            {
                self.togglePopover()
            } else {
                self.showWindow()
            }
        }
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
            let w = (Self.isDebugRun ? SnapshotWindow.self : NSWindow.self).init(
                contentRect: NSRect(x: 0, y: 0, width: 720, height: 760),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered, defer: false)
            w.title = "Colima"
            w.isReleasedWhenClosed = false
            w.contentViewController = NSHostingController(
                rootView:
                    DashboardView(model: model, ui: ui, inWindow: true))
            // The closed window may not be freed yet and still hold the name.
            if !w.setFrameAutosaveName(Self.windowFrameName) { w.setFrameUsingName(Self.windowFrameName) }
            w.delegate = self
            window = w
        }
        guard let w = window else { return }
        if !w.isVisible, !w.isMiniaturized { w.center() }
        setWindowCounted(true)
        NSApp.activate()
        w.makeKeyAndOrderFront(nil)
    }

    /// Counts the window in visibleCount exactly once while it is open, not
    /// minimized and not hidden behind other windows, however that changed.
    private func setWindowCounted(_ on: Bool) {
        guard windowCounted != on else { return }
        windowCounted = on
        model.visibleCount += on ? 1 : -1
    }

    static let windowFrameName = "ColimaBarDashboard"

    func windowWillClose(_ n: Notification) {
        setWindowCounted(false)
        // A closed window keeps its SwiftUI tree, which still runs body on
        // every model change. Release it; showWindow() builds a new one, and
        // ViewState keeps the tab and the search.
        guard let w = n.object as? NSWindow, w === window else { return }
        w.delegate = nil
        window = nil
        DispatchQueue.main.async { w.contentViewController = nil }
    }
    func windowDidMiniaturize(_ n: Notification) { setWindowCounted(false) }
    func windowDidDeminiaturize(_ n: Notification) { setWindowCounted(true) }

    /// A window fully behind other windows, or on a locked or sleeping
    /// screen, stops counting, so stat streams and the fast heartbeat stop.
    func windowDidChangeOcclusionState(_ n: Notification) {
        guard let w = n.object as? NSWindow, w === window else { return }
        setWindowCounted(
            Self.windowCounts(
                visible: w.occlusionState.contains(.visible),
                miniaturized: w.isMiniaturized, debug: Self.isDebugRun))
    }

    /// Whether the dashboard window counts in visibleCount. A debug snapshot
    /// window sits off screen, so it always counts while open.
    nonisolated static func windowCounts(visible: Bool, miniaturized: Bool, debug: Bool) -> Bool {
        !miniaturized && (visible || debug)
    }
}

/// Debug snapshots only: a window that may be taller than the screen, so a
/// whole tab fits in one README screenshot.
final class SnapshotWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}
