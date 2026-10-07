import Foundation

/// The auto-stop rules for one profile. The same rules apply to the
/// selected profile and to each other running profile. Each profile has its
/// own idle time; the timeout setting is the same for all.
enum AutoStopRule {
    /// The result of one check.
    struct Check: Equatable {
        /// When the idle time started, or nil if the profile is not idle.
        var idleSince: Date?
        /// The idle time is over: confirm and stop the VM.
        var isDue: Bool
    }

    /// A profile is idle when auto-stop is on, its VM runs, no VM action
    /// runs, no container runs and its proxies have no active transfers.
    /// `runningContainers` is nil when the list is unknown, for example
    /// after a failed request: then the profile does not count as idle.
    static func evaluate(
        enabled: Bool, isRunning: Bool, isBusy: Bool, runningContainers: Int?, transfers: Int,
        idleSince: Date?, now: Date, idleMinutes: Int
    ) -> Check {
        guard enabled, isRunning, !isBusy, runningContainers == 0, transfers == 0 else {
            return Check(idleSince: nil, isDue: false)
        }
        guard let since = idleSince else { return Check(idleSince: now, isDue: false) }
        return Check(idleSince: since, isDue: now.timeIntervalSince(since) >= Double(idleMinutes * 60))
    }

    /// The running profiles other than the selected one that auto-stop
    /// checks: only the docker runtime has a container list to check.
    static func otherProfiles(_ profiles: [ProfileRow], selected: String) -> [String] {
        profiles.filter {
            $0.isRunning && $0.name != selected && ColimaModel.hasDockerSocket(runtime: $0.runtime)
                && ProfileName.isValid($0.name)
        }
        .map(\.name)
    }

    /// The pause between two container list requests to another profile.
    /// Work through the profile's proxy resets its idle time at each tick.
    static let otherCheckInterval: TimeInterval = 30

    static func isCheckDue(lastCheck: Date?, now: Date) -> Bool {
        guard let lastCheck else { return true }
        return now.timeIntervalSince(lastCheck) >= otherCheckInterval
    }
}
