import Foundation

/// What a container alert says. The title of the banner is the container name.
enum ContainerAlertOutcome: Equatable, Sendable {
    case oom
    case crash(code: String)
    case loop(count: Int, lastCode: String?)
    case unhealthy
    case recovered

    var body: String {
        switch self {
        case .oom: "Killed: out of memory"
        case .crash(let code): "Exited with code \(code)"
        case .loop(let count, let lastCode):
            "Keeps restarting: \(count) exits in \(Int(RestartLoopTracker.window / 60)) minutes."
                + (lastCode.map { " Last exit code \($0)." } ?? "")
        case .unhealthy: "Healthcheck is failing"
        case .recovered: "Healthy again"
        }
    }

    /// Good news is not an entry of the dashboard's list of alerts.
    var isRecovery: Bool { self == .recovered }
}
