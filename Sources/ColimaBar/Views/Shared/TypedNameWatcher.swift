import AppKit

/// Turns a destructive alert button on only while the text field holds the
/// expected text, for example the profile name before a delete.
@MainActor
final class TypedNameWatcher: NSObject, NSTextFieldDelegate {
    let button: NSButton
    let matches: (String) -> Bool

    init(button: NSButton, matches: @escaping (String) -> Bool) {
        self.button = button
        self.matches = matches
    }

    func controlTextDidChange(_ note: Notification) {
        guard let field = note.object as? NSTextField else { return }
        button.isEnabled = matches(field.stringValue)
    }
}
