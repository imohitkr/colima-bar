import Foundation

/// One part of the diagnostics file, in file order. Each part is read on
/// its own, so one failure does not stop the others.
enum DiagnosticsPart: String, CaseIterable, Sendable {
    case app, settings, state, tools, doctor, goodStarts, routes
    case colimaList, colimaStatus, lima, engine, colimaConfig
    case appLog, ctlLog, limaLog, crashReports

    /// The whole run must end in this time, in seconds.
    static let runLimit: TimeInterval = 20

    var title: String {
        switch self {
        case .app: "App"
        case .settings: "Settings"
        case .state: "State"
        case .tools: "Tools"
        case .doctor: "Doctor"
        case .goodStarts: "Good starts"
        case .routes: "Routes"
        case .colimaList: "colima list"
        case .colimaStatus: "colima status"
        case .lima: "Lima"
        case .engine: "Engine"
        case .colimaConfig: "colima.yaml"
        case .appLog: "ColimaBar log"
        case .ctlLog: "ctl.log"
        case .limaLog: "Lima host agent log"
        case .crashReports: "Crash reports"
        }
    }

    /// The time-out of the tool or the read, in seconds, or nil if the part
    /// reads memory or one small file only.
    var timeout: TimeInterval? {
        switch self {
        case .tools, .lima, .engine: 5
        case .routes, .colimaStatus: 8
        case .colimaList, .appLog: 10
        case .doctor: 17
        default: nil
        }
    }

    /// The seconds after which the part counts as failed. It is a little more
    /// than the time-out of its tool, so the tool ends first. Every part ends
    /// before `runLimit`.
    var deadline: TimeInterval { (timeout ?? 5) + 1 }

    /// The most lines and bytes that the part keeps (the end of the text), or
    /// nil if the part has no cap of its own.
    var cap: (lines: Int, bytes: Int)? {
        switch self {
        case .appLog: (1_500, 256 * 1024)
        case .ctlLog: (400, 128 * 1024)
        case .limaLog: (300, 128 * 1024)
        default: nil
        }
    }

    /// Why the part is left out, or nil if it runs. The status and the engine
    /// need a running VM: with a stopped VM they have nothing to say, and a
    /// request to the socket must never start it.
    func skipReason(state: VMState) -> String? {
        switch self {
        case .colimaStatus, .engine:
            switch state {
            case .running: nil
            case .stopped: "the VM is not running"
            case .unknown: "the state of the VM is not known"
            case .notInstalled: "Colima is not installed"
            }
        default: nil
        }
    }

    /// The parts with the reason to skip each one, in file order.
    static func planned(state: VMState) -> [(part: DiagnosticsPart, skipped: String?)] {
        allCases.map { ($0, $0.skipReason(state: state)) }
    }
}
