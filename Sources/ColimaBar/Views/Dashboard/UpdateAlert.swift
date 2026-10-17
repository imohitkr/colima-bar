import AppKit

/// The dialogs of an update. Each one is modal, so the dashboard popover
/// must be closed first (the caller does that).
@MainActor
enum UpdateAlert {
    enum InstallChoice { case install, notes, cancel }
    enum BrewChoice { case copy, terminal, cancel }

    /// A one-button answer, for example for "Check for Updates…". It also
    /// shows when notifications are off.
    static func info(_ title: String, _ text: String) {
        NSApp.activate()
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.addButton(withTitle: "OK")
        a.runModal()
    }

    /// The answer to a click on the version button during an install.
    static func updateInProgress() {
        info("An update is in progress", Help.updateInProgress)
    }

    /// "Install ColimaBar X?": what happens, and how far ColimaBar checks the
    /// download. `attestationSkip` is why `gh` cannot check it, or nil.
    static func confirmInstall(version: String, current: String, attestationSkip: String?) -> InstallChoice {
        NSApp.activate()
        let a = NSAlert()
        a.messageText = "Install ColimaBar \(version)?"
        let check =
            attestationSkip.map {
                "ColimaBar checks the size and the SHA-256 digest of the download against GitHub. It cannot check the build attestation: \($0)."
            }
            ?? "ColimaBar checks the size and the SHA-256 digest of the download against GitHub. It also checks the build attestation with gh."
        a.informativeText = """
            You have version \(current). \(Help.installConfirm)

            \(check)
            """
        a.addButton(withTitle: "Install and Restart")
        a.addButton(withTitle: "Release Notes")
        a.addButton(withTitle: "Cancel").keyEquivalent = "\u{1b}"
        switch a.runModal() {
        case .alertFirstButtonReturn: return .install
        case .alertSecondButtonReturn: return .notes
        default: return .cancel
        }
    }

    /// The Homebrew update: the command, with Copy and Run in Terminal.
    static func homebrew(version: String) -> BrewChoice {
        NSApp.activate()
        let a = NSAlert()
        a.messageText = "Update ColimaBar to \(version) with Homebrew"
        a.informativeText = """
            Homebrew installed this copy, so Homebrew updates it. Run this command:

            \(Updater.brewCommand)

            Homebrew quits ColimaBar. If macOS blocks the new copy at the first start, open System Settings > Privacy & Security and click Open Anyway.
            """
        a.addButton(withTitle: "Copy Command")
        a.addButton(withTitle: "Run in Terminal")
        a.addButton(withTitle: "Cancel").keyEquivalent = "\u{1b}"
        switch a.runModal() {
        case .alertFirstButtonReturn: return .copy
        case .alertSecondButtonReturn: return .terminal
        default: return .cancel
        }
    }

    /// An update that ColimaBar cannot install. True if the user wants the
    /// release page.
    static func link(version: String, current: String, reason: String) -> Bool {
        NSApp.activate()
        let a = NSAlert()
        a.messageText = "ColimaBar \(version) is available"
        a.informativeText =
            "You have \(current). ColimaBar cannot install it, because \(reason). Open the release page to download it?"
        a.addButton(withTitle: "Open Release Page")
        a.addButton(withTitle: "Later").keyEquivalent = "\u{1b}"
        return a.runModal() == .alertFirstButtonReturn
    }
}
