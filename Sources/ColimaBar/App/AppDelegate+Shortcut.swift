import AppKit

extension AppDelegate {
    /// The action for one press. A modal window gets no action. An open
    /// dashboard closes. A window that is open but not in front comes to the
    /// front. Else the dashboard opens.
    nonisolated static func shortcutAction(
        modal: Bool, popoverShown: Bool, windowOpen: Bool, windowFront: Bool
    ) -> ShortcutAction {
        if modal { return .nothing }
        if popoverShown { return .closePopover }
        if windowOpen { return windowFront ? .closeWindow : .showWindow }
        return .reveal
    }

    /// Runs when the user presses the dashboard shortcut.
    func toggleDashboard() {
        let front = window.map { NSApp.isActive && $0.isKeyWindow } ?? false
        switch Self.shortcutAction(
            modal: NSApp.modalWindow != nil, popoverShown: popover.isShown, windowOpen: window != nil,
            windowFront: front)
        {
        case .nothing: break
        case .closePopover: popover.performClose(nil)
        case .closeWindow: window?.performClose(nil)
        case .showWindow: showWindow()
        case .reveal: revealDashboard()
        }
    }
}
