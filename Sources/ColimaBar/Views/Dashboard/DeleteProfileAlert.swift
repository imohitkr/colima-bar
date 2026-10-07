import AppKit

/// The in-app warning before a profile delete. The user must type the
/// profile name before the destructive button works. colima-ctl.sh asks one
/// more time before it deletes anything.
@MainActor
enum DeleteProfileAlert {
    /// True only if the user typed the profile name and clicked the
    /// destructive button.
    static func confirm(profile: String, isRunning: Bool) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Delete the profile \(profile) and all its data?"
        alert.informativeText = ProfileDelete.warning(profile: profile, isRunning: isRunning)
        let delete = alert.addButton(withTitle: "Delete Profile")
        delete.hasDestructiveAction = true
        delete.isEnabled = false
        delete.keyEquivalent = ""  // Return must not delete the data
        alert.addButton(withTitle: "Cancel").keyEquivalent = "\u{1b}"

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = profile
        field.setAccessibilityLabel("Profile name")
        let watcher = TypedNameWatcher(button: delete) { ProfileDelete.confirms(typed: $0, profile: profile) }
        field.delegate = watcher
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        NSApp.activate()
        let answer = alert.runModal()
        field.delegate = nil
        return answer == .alertFirstButtonReturn && ProfileDelete.confirms(typed: field.stringValue, profile: profile)
    }
}
