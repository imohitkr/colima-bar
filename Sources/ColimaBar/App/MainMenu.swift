import AppKit

extension AppDelegate {
    /// Accessory apps show no menu bar, but key equivalents still route
    /// through the main menu: without it ⌘C/⌘V/⌘A/⌘W do nothing.
    func installMainMenu() {
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
}
