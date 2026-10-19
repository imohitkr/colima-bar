import AppKit

/// The question before a link starts, stops or restarts a VM. A link comes
/// from another app or a web page, so the question must not take a key press
/// that the user typed for another app.
@MainActor
enum LinkAlert {
    struct Answer: Equatable {
        /// The user clicked the action button.
        let confirmed: Bool
        /// The user ticked the box and clicked the action button.
        let stopAsking: Bool
    }

    static func confirm(_ action: AppLink.VMAction, profile: String, model: ColimaModel) -> Answer {
        let dialog = AppLinkPolicy.dialog(action, profile: profile)
        model.dismissPopover()
        let alert = NSAlert()
        alert.messageText = dialog.title
        alert.informativeText = dialog.text
        let button = alert.addButton(withTitle: dialog.button)
        button.hasDestructiveAction = dialog.destructive
        button.keyEquivalent = ""  // Return must not run the link
        alert.addButton(withTitle: "Cancel").keyEquivalent = "\u{1b}"
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = AppLinkPolicy.suppressionTitle
        NSApp.activate()
        let confirmed = alert.runModal() == .alertFirstButtonReturn
        return Answer(confirmed: confirmed, stopAsking: confirmed && alert.suppressionButton?.state == .on)
    }

    /// Shows the text of a refused or bad link, when notifications are off.
    /// The only button is OK, so a key press cannot run anything.
    static func inform(_ text: String, model: ColimaModel) {
        model.dismissPopover()
        let alert = NSAlert()
        alert.messageText = AppLinkPolicy.noticeTitle
        alert.informativeText = text
        alert.addButton(withTitle: "OK")
        NSApp.activate()
        alert.runModal()
    }
}
