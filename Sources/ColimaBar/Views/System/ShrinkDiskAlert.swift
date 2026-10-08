import AppKit

/// The in-app warning before a disk shrink. The user must type the profile
/// name before the destructive button works. colima-ctl.sh asks one more
/// time before it deletes anything.
@MainActor
enum ShrinkDiskAlert {
    /// True only if the user typed the profile name and clicked the
    /// destructive button. `running` is the VM state of the profile.
    static func confirm(
        profile: String, from: Int, to: Int, usage: [DFRow], kubernetes: Bool, running: Bool
    ) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Delete all Docker data and shrink the disk to \(to) GB?"
        alert.informativeText = DiskShrink.warning(
            profile: profile, from: from, to: to, usage: usage, kubernetes: kubernetes, running: running)
        let delete = alert.addButton(withTitle: "Delete Data and Shrink")
        delete.hasDestructiveAction = true
        delete.isEnabled = false
        delete.keyEquivalent = ""  // Return must not delete the data
        alert.addButton(withTitle: "Cancel").keyEquivalent = "\u{1b}"

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = profile
        field.setAccessibilityLabel("Profile name")
        let watcher = TypedNameWatcher(button: delete) { DiskShrink.confirms(typed: $0, profile: profile) }
        field.delegate = watcher
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        NSApp.activate()
        let answer = alert.runModal()
        field.delegate = nil
        return answer == .alertFirstButtonReturn && DiskShrink.confirms(typed: field.stringValue, profile: profile)
    }
}
