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
    /// dashboard ends the current sleep at once. On battery it runs every 10
    /// seconds. In Low Power Mode or on a hot Mac it runs every 15 seconds.
    /// The model passes `.off` while a dashboard is open or an action runs.
    nonisolated static func tickInterval(
        state: VMState, busy: Bool, dashboardOpen: Bool, saving: PowerState.Saving = .off
    ) -> Duration {
        guard !busy, !dashboardOpen else { return .seconds(1) }
        switch saving {
        case .off: return .seconds(5)
        case .battery: return .seconds(10)
        case .strong: return .seconds(15)
        }
    }

    /// The time between two pings of the Docker socket. Each one is a whole
    /// number of ticks.
    nonisolated static func pingInterval(dashboardOpen: Bool, saving: PowerState.Saving = .off) -> TimeInterval {
        guard !dashboardOpen else { return 3 }
        switch saving {
        case .off: return 10
        case .battery: return 20
        case .strong: return 30
        }
    }

    /// How old the last `colima list` can be before the heartbeat runs it
    /// again. The directory watcher and the socket ping catch state changes,
    /// so a running or stopped VM needs only a rare check, and a rarer one
    /// when the power state saves.
    nonisolated static func staleAfter(state: VMState, saving: PowerState.Saving = .off) -> TimeInterval {
        guard state == .stopped || state == .running else { return 60 }
        switch saving {
        case .off: return 5 * 60
        case .battery: return 10 * 60
        case .strong: return 15 * 60
        }
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

    /// The busy label of a profile for `updateActivity`: the busy marker, or
    /// an empty label for an action that this app runs without a marker, or
    /// nil if the profile is not busy.
    nonisolated static func updateBusyLabel(marker: String?, actionsInFlight: Int) -> String? {
        marker ?? (actionsInFlight > 0 ? "" : nil)
    }

    /// A profile is not idle while a VM action runs (its busy marker) or
    /// while any colima-ctl.sh action that ColimaBar started still runs.
    /// For example, a prune can wait minutes for its dialog, then needs the VM.
    nonisolated static func blocksAutoStop(busyMarker: String?, actionsInFlight: Int) -> Bool {
        busyMarker != nil || actionsInFlight > 0
    }

    /// The check after a system sleep skips a profile that blocks auto-stop,
    /// and a profile that an auto-start (`starting`) wakes now. They report
    /// their own failures.
    nonisolated static func blocksSleepCheck(busyMarker: String?, actionsInFlight: Int, starting: Bool) -> Bool {
        blocksAutoStop(busyMarker: busyMarker, actionsInFlight: actionsInFlight) || starting
    }

    /// What the Restart button of an alert does for a profile.
    enum AlertRestart: Equatable {
        case restart, missing, busy, stopped
    }

    /// Restart only a profile that still exists, has no action, and has a
    /// running VM. Else `colima start` could make a new VM or start a VM that
    /// the user stopped.
    nonisolated static func alertRestart(exists: Bool, blocked: Bool, running: Bool) -> AlertRestart {
        guard exists else { return .missing }
        guard !blocked else { return .busy }
        return running ? .restart : .stopped
    }

    /// Whether the profile menu offers Start (`start`) or Stop for a profile.
    /// The selected profile uses its live state; another profile uses its
    /// row in the last `colima list`. A profile with an action that runs
    /// gets neither.
    nonisolated static func profileAction(
        start: Bool, isSelected: Bool, state: VMState, listedRunning: Bool, busy: Bool
    ) -> Bool {
        guard !busy else { return false }
        guard isSelected else { return start != listedRunning }
        return start ? state == .stopped : state == .running
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

    /// After a failed docker context check, the check runs again after this time.
    nonisolated static let contextCheckRetryInterval: TimeInterval = 60

    /// A failed check is retried at most this many times in a row.
    nonisolated static let contextCheckMaxRetries = 3

    /// When to retry after a failed check, or nil after too many failures.
    /// `failures` counts the failures in a row, this one included.
    nonisolated static func contextCheckRetryAt(failures: Int, now: Date) -> Date? {
        failures <= contextCheckMaxRetries ? now.addingTimeInterval(contextCheckRetryInterval) : nil
    }

    /// True if the docker context check is due on this tick: the config file
    /// changed, or a failed check can run again.
    nonisolated static func contextCheckDue(
        stamp: Date?, lastStamp: Date?, retryAt: Date?, now: Date
    ) -> Bool {
        stamp != lastStamp || retryAt.map { now >= $0 } ?? false
    }
}
