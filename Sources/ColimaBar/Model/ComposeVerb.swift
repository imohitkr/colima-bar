import Foundation

/// What the project menu runs through `colima-ctl.sh`.
enum ComposeVerb: String, CaseIterable, Sendable {
    case pull
    case up
    case down
    /// `down --remove-orphans`. The script asks first, and adds `--volumes`
    /// only after a click on Delete Volumes.
    case remove

    var action: CtlAction {
        switch self {
        case .pull: .composePull
        case .up: .composeUp
        case .down: .composeDown
        case .remove: .composeRemove
        }
    }

    /// The word for notifications: "Compose pull failed".
    var title: String { rawValue }
}
