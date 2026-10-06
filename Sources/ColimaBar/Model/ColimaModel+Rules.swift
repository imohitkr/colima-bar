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
    nonisolated static func showsDiskUsage(_ tab: Tab) -> Bool { tab != .containers }

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

    /// Actions that change disk use. When one ends, df runs at once, so a
    /// removed image or volume leaves its row and a second Remove can't fail.
    nonisolated static func changesDisk(_ action: String) -> Bool {
        ["ctr-rm", "img-rm", "img-pull", "vol-rm", "prune", "stop-all"].contains(action)
    }

    nonisolated static let projectConcurrency = 8
}
