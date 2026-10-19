import Foundation

/// What the project menu runs through `colima-ctl.sh`.
enum ComposeVerb: String, CaseIterable, Sendable {
    case pull
    case up
    case down

    var action: CtlAction {
        switch self {
        case .pull: .composePull
        case .up: .composeUp
        case .down: .composeDown
        }
    }

    /// The word for notifications: "Compose pull failed".
    var title: String { rawValue }
}
