import Foundation

extension ColimaModel {
    /// The icon hides only when the VM is known to be stopped, nothing is in
    /// progress and no other profile's VM runs. Unknown and not-installed
    /// states keep it visible.
    nonisolated static func hidesIcon(
        enabled: Bool, revealed: Bool, state: VMState, busy: Bool,
        dashboardOpen: Bool, otherProfileRunning: Bool = false
    ) -> Bool {
        enabled && !revealed && state == .stopped && !busy && !dashboardOpen && !otherProfileRunning
    }

    /// The heartbeat runs once a second while a dashboard is open or an
    /// action is in progress. Otherwise it runs every 5 seconds, also while
    /// the VM runs: auto-stop does not need finer steps, and opening the
    /// dashboard ends the current sleep at once.
    nonisolated static func tickInterval(state: VMState, busy: Bool, dashboardOpen: Bool) -> Duration {
        !busy && !dashboardOpen ? .seconds(5) : .seconds(1)
    }

    /// How old the last `colima list` can be before the heartbeat runs it
    /// again. The directory watcher and the socket ping catch state changes,
    /// so a running or stopped VM needs only a rare check.
    nonisolated static func staleAfter(state: VMState) -> TimeInterval {
        state == .stopped || state == .running ? 5 * 60 : 60
    }

    /// Opening the dashboard runs `colima list` only when the last one is at
    /// least this old.
    nonisolated static let statusMaxAgeOnOpen: TimeInterval = 60

    /// The Images, Volumes and System tabs show data from `/system/df`.
    nonisolated static func showsDiskUsage(_ tab: DashboardTab) -> Bool { tab != .containers }

    nonisolated static func derivedLists(_ containers: [Container])
        -> (running: [Container], stopped: [Container], unhealthy: Int)
    {
        (
            containers.filter(\.isRunning), containers.filter { !$0.isRunning },
            containers.reduce(0) { $0 + ($1.health == "unhealthy" ? 1 : 0) }
        )
    }

    nonisolated static func hasDockerSocket(runtime: String) -> Bool {
        runtime.isEmpty || runtime == "docker"
    }

    nonisolated static let projectConcurrency = 8

    /// True when the exit code of a `die` event is a failure. Then the crash
    /// alert goes out, and `RemovedLogKeeper` keeps the logs. No code, 0 and
    /// the codes in `ignoredExitCodes` are a normal stop.
    nonisolated static func isCrashExit(_ code: String?) -> Bool {
        guard let code else { return false }
        return !ignoredExitCodes.contains(code)
    }

    /// Whether the selected profile counts as running, for Delete Profile.
    /// `listed` is its state in the last `colima list`, nil if the list does
    /// not show it. Right after a switch the state is unknown: then the list
    /// decides, and no list entry counts as running.
    nonisolated static func selectedIsRunning(state: VMState, listed: Bool?) -> Bool {
        switch state {
        case .running: true
        case .unknown: listed ?? true
        case .stopped, .notInstalled: false
        }
    }

    /// A profile is not idle while a VM action runs (its busy marker) or
    /// while any colima-ctl.sh action that ColimaBar started still runs.
    /// For example, a prune can wait minutes for its dialog, then needs the VM.
    nonisolated static func blocksAutoStop(busyMarker: String?, actionsInFlight: Int) -> Bool {
        busyMarker != nil || actionsInFlight > 0
    }

    /// The proxies to hold while wakes run (see SocketProxy.holdForWake).
    /// `waking` holds the profiles whose wake runs now. The stable proxy
    /// follows the selected profile. Each profile proxy follows its own
    /// profile, also a proxy that is made again during the wake.
    nonisolated static func holds(waking: Set<String>, selected: String) -> (stable: Bool, profiles: Set<String>) {
        (waking.contains(selected), waking)
    }

    /// After `ProfileContexts.apply` fails, the same wanted set runs again
    /// only after this time. Each `colima list` would run the docker CLI again.
    nonisolated static let contextsRetryInterval: TimeInterval = 30 * 60

    /// True if the `colimabar-PROFILE` contexts can be applied for `wanted`
    /// after the apply for `failed` failed at `failedAt`. A new set runs at once.
    nonisolated static func contextsRetryDue(
        wanted: [String: String], failed: [String: String], failedAt: Date, now: Date
    ) -> Bool {
        wanted != failed || now.timeIntervalSince(failedAt) >= contextsRetryInterval
    }
}
