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
    /// Deletes the VM with all its data and starts it with a smaller disk.
    case diskShrink = "disk-shrink"
    case autoStop = "auto-stop"
    /// Creates a new profile with `colima start` and starts its VM.
    case profileCreate = "profile-create"
    /// Deletes a profile with `colima delete --data --force`.
    case profileDelete = "profile-delete"
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
        case .start, .stop, .restart, .resources, .rosetta, .k8s, .disk, .diskShrink, .autoStop, .profileCreate,
            .profileDelete:
            true
        default: false
        }
    }

    /// Changes disk use. When it ends, df runs at once, so a removed image
    /// or volume leaves its row and a second Remove can't fail.
    var changesDisk: Bool {
        switch self {
        case .containerRemove, .imageRemove, .imagePull, .volumeRemove, .prune, .stopAll, .diskShrink: true
        default: false
        }
    }

    /// While the VM is stopped, the script only writes the new value to
    /// colima.yaml. It does not start the VM. The value applies at the
    /// next start.
    var editsConfigWhenStopped: Bool {
        switch self {
        case .resources, .rosetta, .k8s, .disk: true
        default: false
        }
    }

    /// The script asks the user with a dialog first. The dialog comes from
    /// another process, so ColimaBar closes the popover before it runs:
    /// the popover would cover the dialog. `running` is the VM state of the
    /// profile. A stopped VM saves CPU, memory, Rosetta and Kubernetes with
    /// no dialog. A disk change still asks: a grow becomes permanent at the
    /// next start. A test checks the running list against the script.
    func showsDialog(running: Bool) -> Bool {
        switch self {
        case .resources, .rosetta, .k8s: running
        case .disk, .diskShrink, .profileDelete, .containerRemove, .imageRemove, .volumeRemove, .stopAll, .prune:
            true
        default: false
        }
    }

    /// The script asks with a dialog only in one VM state. ColimaBar sends
    /// the state that it expects in `COLIMABAR_EXPECT_RUNNING`. If the VM
    /// is in the other state, the script changes nothing and exits with 1.
    /// Thus no dialog opens behind the popover.
    var checksExpectedState: Bool {
        showsDialog(running: true) != showsDialog(running: false)
    }

    /// The environment that ColimaBar gives the script. `expectRunning` is
    /// the VM state that `run` used for `showsDialog(running:)`. It goes in
    /// `COLIMABAR_EXPECT_RUNNING` (1 or 0) only for an action that checks it.
    func environment(profile: String, expectRunning: Bool?) -> [String: String] {
        var env = ["COLIMABAR_PROFILE": profile, "COLIMABAR_APP": "1"]
        if let expectRunning, checksExpectedState {
            env["COLIMABAR_EXPECT_RUNNING"] = expectRunning ? "1" : "0"
        }
        return env
    }

    /// The busy text the UI shows for a VM action until the script writes
    /// its own marker. A config edit of a stopped VM writes no marker, so
    /// "Saving" shows until the script ends.
    func busyLabel(running: Bool) -> String? {
        guard isVMAction else { return nil }
        if !running, editsConfigWhenStopped { return "Saving" }
        switch self {
        case .start: return "Starting"
        case .stop, .autoStop: return "Stopping"
        case .diskShrink: return "Shrinking disk"
        case .profileCreate: return "Creating"
        case .profileDelete: return "Deleting"
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
