import AppKit

/// Asks for a namespace name that the lists do not show ("Other…"). The OK
/// button works only for a valid name (`KubeNamespace.isValid`).
@MainActor
enum KubeNamespaceAlert {
    /// `context` is the context that the menu showed. The namespace goes only to it.
    static func ask(model: ColimaModel, context: String) {
        // The popover would cover the alert.
        model.dismissPopover()
        let alert = NSAlert()
        alert.messageText = "Namespace of \(context)"
        alert.informativeText =
            "Type the name of a namespace. Use 1 to 63 lower-case letters, digits and -. The first and the last character must be a letter or a digit. ColimaBar sets it with kubectl config set-context."
        let set = alert.addButton(withTitle: "Set Namespace")
        alert.addButton(withTitle: "Cancel").keyEquivalent = "\u{1b}"
        set.isEnabled = false

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = "default"
        field.setAccessibilityLabel("Namespace")
        let watcher = TypedNameWatcher(button: set, matches: KubeNamespace.isValid)
        field.delegate = watcher
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        NSApp.activate()
        let answer = alert.runModal()
        field.delegate = nil
        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard answer == .alertFirstButtonReturn, KubeNamespace.isValid(name) else { return }
        Task { await model.setKubeNamespace(name, context: context) }
    }
}
