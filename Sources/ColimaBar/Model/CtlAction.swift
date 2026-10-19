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
    /// Replaces colima.yaml with a file that ColimaBar staged, after a check of
    /// the SHA-256 of the old file (the advanced VM settings). Args: the
    /// staged file and the SHA-256.
    case vmConfig = "vm-config"
    /// Deletes the VM with all its data and starts it with a smaller disk.
    case diskShrink = "disk-shrink"
    case autoStop = "auto-stop"
    /// Creates a new profile with `colima start` and starts its VM.
    case profileCreate = "profile-create"
    /// Deletes a profile with `colima delete --data --force`.
    case profileDelete = "profile-delete"
    /// Stops the VM by force, removes the stale pid files of Lima and starts
    /// the VM again (Doctor).
    case repair
    /// Lists the pid files of Lima that it cannot use. Read-only: no lock,
    /// no busy marker and no `colima` call.
    case staleFiles = "stale-files"
    case copyEnv = "copy-env"
    case containerRemove = "ctr-rm"
    case containerLogs = "ctr-logs"
    case containerShell = "ctr-shell"
    /// `docker compose pull`, `up -d` and `down` of a Compose project. Args:
    /// `NAME DIR NENV ENV... FILE...` (see `ComposeProject.ctlArgs()`). They are
    /// not VM actions: no lock and no busy marker. `ColimaModel.compose`
    /// runs them, and their output never goes to ctl.log.
    case composePull = "compose-pull"
    case composeUp = "compose-up"
    case composeDown = "compose-down"
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
        case .start, .stop, .restart, .resources, .rosetta, .k8s, .disk, .vmConfig, .diskShrink, .autoStop,
            .profileCreate, .profileDelete, .repair:
            true
        default: false
        }
    }

    /// Changes disk use. When it ends, df runs at once, so a removed image
    /// or volume leaves its row and a second Remove can't fail.
    var changesDisk: Bool {
        switch self {
        case .containerRemove, .imageRemove, .imagePull, .volumeRemove, .prune, .stopAll, .diskShrink, .composePull,
            .composeDown:
            true
        default: false
        }
    }

    /// While the VM is stopped, the script only writes the new value to
    /// colima.yaml. It does not start the VM. The value applies at the
    /// next start.
    var editsConfigWhenStopped: Bool {
        switch self {
        case .resources, .rosetta, .k8s, .disk, .vmConfig: true
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
        case .resources, .rosetta, .k8s, .vmConfig: running
        case .disk, .diskShrink, .profileDelete, .repair, .containerRemove, .imageRemove, .volumeRemove, .stopAll,
            .prune, .composeDown:
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

    /// A good run of this action leaves the VM freshly started. `running` is
    /// the VM state before the action. `start` counts only for a stopped VM.
    /// A config change counts only while the VM runs: then the script restarts it.
    func startsVM(running: Bool) -> Bool {
        switch self {
        case .start: !running
        case .restart, .repair, .profileCreate, .diskShrink: true
        case .resources, .rosetta, .k8s, .disk, .vmConfig: running
        default: false
        }
    }

    /// The script asks again after an upgrade of Colima or Lima, for a start
    /// that the user begins in the menu. `repair` has its own dialog and a
    /// Doctor row, `diskShrink` deletes the data anyway and `profileCreate`
    /// has no record.
    func warnsAfterUpgrade(running: Bool) -> Bool {
        switch self {
        case .start, .restart, .resources, .rosetta, .k8s, .disk, .vmConfig: startsVM(running: running)
        default: false
        }
    }

    /// The environment that ColimaBar gives the script. `expectRunning` is
    /// the VM state that `run` used for `showsDialog(running:)`. It goes in
    /// `COLIMABAR_EXPECT_RUNNING` (1 or 0) only for an action that checks it.
    /// `upgrade` is the note and the release-notes pages of a risky upgrade.
    /// It goes in only for an action that warns after an upgrade.
    func environment(
        profile: String, expectRunning: Bool?, upgrade: (note: String, releaseNotes: [URL])? = nil
    ) -> [String: String] {
        var env = ["COLIMABAR_PROFILE": profile, "COLIMABAR_APP": "1"]
        if let upgrade, warnsAfterUpgrade(running: expectRunning ?? false) {
            env["COLIMABAR_UPGRADE_NOTE"] = upgrade.note
            env["COLIMABAR_RELEASE_NOTES"] = upgrade.releaseNotes.map(\.absoluteString).joined(separator: " ")
        }
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
        case .vmConfig: return "Applying VM settings"
        case .diskShrink: return "Shrinking disk"
        case .profileCreate: return "Creating"
        case .profileDelete: return "Deleting"
        case .repair: return "Repairing"
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
