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

    private let model = ColimaModel()
    private let ui = ViewState()
    private var item: NSStatusItem!
    private let popover = NSPopover()
    private var window: NSWindow?

    func applicationDidFinishLaunching(_ note: Notification) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.target = self
        item.button?.action = #selector(clicked)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        item.button?.imagePosition = .imageLeading

        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self
        popover.contentViewController = NSHostingController(rootView:
            DashboardView(model: model, ui: ui, openWindow: { [weak self] in self?.showWindow() }))

        model.start()
        updateIcon()
        registerLoginItemOnce()
        if CommandLine.arguments.contains("--window") { showWindow() }
        // Debug: `--snapshot PATH [TAB]` renders the dashboard window to a PNG
        // a few seconds after launch (no Screen Recording permission needed).
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
            if i + 2 < args.count, let tab = Tab(rawValue: args[i + 2]) { ui.tab = tab }
            showWindow()
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
                self?.snapshot(to: args[i + 1])
                NSApp.terminate(nil)
            }
        }
    }

    private func snapshot(to path: String) {
        guard let view = window?.contentView, let layer = view.layer else { return }
        let scale = window?.backingScaleFactor ?? 2
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
            item.button?.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        } onChange: {
            Task { @MainActor [weak self] in self?.updateIcon() }
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
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(.separator())
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
        try? SMAppService.mainApp.register()
    }

    @objc private func startVM() { model.ctl("start") }
    @objc private func stopVM() { model.ctl("stop") }
    @objc private func restartVM() { model.ctl("restart") }
    @objc private func openWindowAction() { showWindow() }
    @objc private func quit() { NSApp.terminate(nil) }
    @objc private func toggleLogin() {
        let svc = SMAppService.mainApp
        do {
            if svc.status == .enabled { try svc.unregister() } else { try svc.register() }
        } catch {
            model.notify("Login item change failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Visibility drives live stats

    func popoverWillShow(_ n: Notification) { model.visibleCount += 1 }
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
