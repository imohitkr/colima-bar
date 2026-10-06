import Foundation

/// The actions of scripts/colima-ctl.sh that ColimaBar runs. Each raw value
/// is a `case` label in the script. Do not change a raw value without the
/// script: a test checks that every one appears there.
enum CtlAction: String, CaseIterable, Sendable {
    case start
    case stop
    case restart
    case resources
    case rosetta
    case k8s
    case disk
    case autoStop = "auto-stop"
    case copyEnv = "copy-env"
    case containerRemove = "ctr-rm"
    case containerLogs = "ctr-logs"
    case containerShell = "ctr-shell"
    case imageRemove = "img-rm"
    case imagePull = "img-pull"
    case volumeRemove = "vol-rm"
    case stopAll = "stop-all"
    case prune
    case ssh
    case config
    case logs

    /// Starts, stops or restarts the VM. The UI shows it as busy right away,
    /// not on the next 1 s tick, so a second click can't race it.
    var isVMAction: Bool {
        switch self {
        case .start, .stop, .restart, .resources, .rosetta, .k8s, .disk, .autoStop: true
        default: false
        }
    }

    /// Changes disk use. When it ends, df runs at once, so a removed image
    /// or volume leaves its row and a second Remove can't fail.
    var changesDisk: Bool {
        switch self {
        case .containerRemove, .imageRemove, .imagePull, .volumeRemove, .prune, .stopAll: true
        default: false
        }
    }

    /// The busy text the UI shows for a VM action until the script writes
    /// its own marker.
    var busyLabel: String? {
        guard isVMAction else { return nil }
        switch self {
        case .start: return "Starting"
        case .stop, .autoStop: return "Stopping"
        default: return "Restarting"
        }
    }
}

/// Container lifecycle calls that go straight to the Docker API. The raw
/// value is the API path segment.
enum ContainerVerb: String, Sendable {
    case start
    case stop
    case restart
}
