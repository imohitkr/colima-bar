import Foundation

/// The rules for a parsed link: which checks stop it, whether it asks first,
/// and every text that it shows. Pure, so tests can call it without a VM.
enum AppLinkPolicy {
    /// What the model knows when the link runs, after a fresh `colima list`.
    struct Facts: Equatable, Sendable {
        /// The app restarts for an update, or will do so now.
        var updating = false
        var colimaMissing = false
        /// `colima list` gave no list.
        var listFailed = false
        /// The profile is in the list. A link never creates a VM.
        var profileExists = true
        /// An action runs for the profile (a busy marker exists).
        var busy = false
        var running = false
    }

    /// The reasons that a link does not run. The numbers are the R1 to R6
    /// of the design.
    enum Refusal: Equatable, Sendable {
        case updating
        case colimaMissing
        case listFailed
        case profileMissing
        case busy
        case stopped
    }

    enum Outcome: Equatable, Sendable {
        case run
        /// Nothing to do: start of a running VM, stop of a stopped VM.
        case nothing
        case refuse(Refusal)
    }

    /// Builds the facts from what the model knows after the list was read.
    /// `listed` is false if `colima list` gave no list.
    static func facts(
        profile: String, profiles: [ProfileRow], updating: Bool, colimaMissing: Bool, listed: Bool,
        busyMarker: String?
    ) -> Facts {
        if updating { return Facts(updating: true) }
        let row = profiles.first { $0.name == profile }
        return Facts(
            colimaMissing: colimaMissing, listFailed: !listed, profileExists: row != nil, busy: busyMarker != nil,
            running: row?.isRunning ?? false)
    }

    /// True if the list must be read once more. `refreshStatus` also gives
    /// false when the profile changed during the call (a deleted profile
    /// switches to default), and then the list is fine. A missing Colima has
    /// its own refusal.
    static func needsSecondRead(listed: Bool, colimaMissing: Bool) -> Bool {
        !listed && !colimaMissing
    }

    /// Where the text of a refused or bad link goes.
    enum Channel: Equatable, Sendable {
        /// A notification, and the dashboard list of alerts.
        case notification
        /// An alert window. macOS shows no notification, so a failure
        /// would stay silent.
        case alert
    }

    static func channel(notificationsAllowed: Bool) -> Channel {
        notificationsAllowed ? .notification : .alert
    }

    /// Checks the gates in this order: update, Colima, list, profile, busy
    /// marker, state. The busy marker comes before the state, because a VM
    /// in an action has no stable state.
    static func decide(_ action: AppLink.VMAction, _ facts: Facts) -> Outcome {
        if facts.updating { return .refuse(.updating) }
        if facts.colimaMissing { return .refuse(.colimaMissing) }
        if facts.listFailed { return .refuse(.listFailed) }
        if !facts.profileExists { return .refuse(.profileMissing) }
        if facts.busy { return .refuse(.busy) }
        switch action {
        case .start: return facts.running ? .nothing : .run
        case .stop: return facts.running ? .run : .nothing
        case .restart: return facts.running ? .run : .refuse(.stopped)
        }
    }

    /// True if the link asks before it runs. Only VM links ask, and only
    /// while the setting is on.
    static func asks(_ link: AppLink, setting: Bool) -> Bool {
        guard setting else { return false }
        if case .vm = link { return true }
        return false
    }

    // MARK: - Notification texts

    /// The notification for a text that is not a link.
    static func text(for failure: AppLink.Failure) -> String {
        switch failure {
        case .tooLong, .malformed, .wrongScheme, .unknownRoute:
            "ColimaBar cannot use this link. Use colimabar://open, doctor, start, stop or restart."
        case .badParameter:
            "ColimaBar cannot use this link. Only start, stop and restart take a parameter: profile=NAME."
        case .badProfile:
            "The profile name in the link is not valid. Use a name that colima list shows."
        }
    }

    /// The notification for a link that ColimaBar refuses to run.
    static func text(for refusal: Refusal, action: AppLink.VMAction, profile: String) -> String {
        switch refusal {
        case .updating:
            "ColimaBar restarts for an update now. Try the link again in a few seconds."
        case .colimaMissing:
            "Colima isn't installed, so ColimaBar did not run the link. Install it with Homebrew: brew install colima docker"
        case .listFailed:
            "ColimaBar could not read the Colima profiles, so it did not run the link. Try again."
        case .profileMissing:
            "Profile \(profile) doesn't exist, so it wasn't \(past(action))."
        case .busy:
            AfterSleepCheck.restartBusyText(profile: profile)
        case .stopped:
            AfterSleepCheck.restartStoppedText(profile: profile)
        }
    }

    private static func past(_ action: AppLink.VMAction) -> String {
        switch action {
        case .start: "started"
        case .stop: "stopped"
        case .restart: "restarted"
        }
    }

    // MARK: - Question

    /// The question before a link starts, stops or restarts a VM.
    struct Dialog: Equatable, Sendable {
        let title: String
        let text: String
        /// The title of the action button.
        let button: String
        /// Stop and restart end running containers.
        let destructive: Bool
    }

    /// The title of the alert that shows a link text when notifications are off.
    static let noticeTitle = "ColimaBar link"

    static let suppressionTitle = "Do not ask again for links"

    static func dialog(_ action: AppLink.VMAction, profile: String) -> Dialog {
        let title = { (verb: String) in "\(verb) the VM of profile '\(profile)'?" }
        switch action {
        case .start:
            return Dialog(
                title: title("Start"),
                text:
                    "A link from another app or a web page asks to start this VM. The VM uses memory and battery while it runs.",
                button: "Start", destructive: false)
        case .stop:
            return Dialog(
                title: title("Stop"),
                text: "A link from another app or a web page asks to stop this VM. Its running containers stop.",
                button: "Stop", destructive: true)
        case .restart:
            return Dialog(
                title: title("Restart"),
                text:
                    "A link from another app or a web page asks to restart this VM. Running containers stop. Only containers with a restart policy start again.",
                button: "Restart", destructive: true)
        }
    }
}
