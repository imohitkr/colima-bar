import Foundation

/// The rules of the weekly cleanup. The functions are pure. `ColimaModel`
/// reads the inputs at each tick and runs `auto-prune` of colima-ctl.sh.
enum PruneSchedule {
    static let interval: TimeInterval = 7 * 24 * 3600
    /// After an exit 2 (VM stopped, start in progress, lock held), try again after this time.
    static let retryAfter: TimeInterval = 60 * 60
    /// After an exit 1 (the cleanup failed and the script notified), try again
    /// after this time. A failure then notifies at most four times a day.
    static let failedRetryAfter: TimeInterval = 6 * 3600
    /// A last run that is this far in the future is a wrong date, for example
    /// after a clock change. It must not block the cleanup for ever.
    static let futureTolerance: TimeInterval = 24 * 3600

    /// True when a weekly cleanup of the profile is due. No last run means
    /// due. A last run more than a day in the future counts as wrong: due.
    /// `retryAt` is the time before which ColimaBar does not try again. One
    /// that is further away than the longest wait counts as wrong: ignored.
    static func isDue(lastRun: Date?, retryAt: Date?, now: Date) -> Bool {
        if let retryAt, now < retryAt, retryAt.timeIntervalSince(now) <= failedRetryAfter { return false }
        guard let lastRun else { return true }
        let age = now.timeIntervalSince(lastRun)
        if age < -futureTolerance { return true }
        return age >= interval
    }

    /// The time before which ColimaBar does not try again after a run that
    /// ended with `status`, or nil when no wait is needed (a good run).
    static func retryAt(afterStatus status: Int32, now: Date) -> Date? {
        switch status {
        case 0: nil
        case 1: now.addingTimeInterval(failedRetryAfter)
        default: now.addingTimeInterval(retryAfter)
        }
    }

    /// The inputs that the model reads at a tick. All must allow the run.
    /// `proxyTransfers` is the live docker traffic of the profile: the signal
    /// of auto-stop. A build or a pull shows no running container, and a
    /// prune can delete the image that it is about to use. `trimming` is a
    /// Return Free Space run that has not started its script yet.
    static func mayRun(
        enabled: Bool, isDebug: Bool, updateRestarting: Bool, running: Bool, hasDockerSocket: Bool,
        busyMarker: String?, actionsInFlight: Int, waking: Bool, transferring: Bool, proxyTransfers: Int,
        trimming: Bool = false
    ) -> Bool {
        enabled && !isDebug && !updateRestarting && running && hasDockerSocket && busyMarker == nil
            && actionsInFlight == 0 && !waking && !transferring && proxyTransfers == 0 && !trimming
    }

    /// Only exit 0 counts as a run. After exit 1 and 2 the cleanup is still due.
    static func countsAsRun(status: Int32) -> Bool { status == 0 }

    /// The stored value of `Defaults.Key.scheduledPruneLastRun`: profile to
    /// seconds since 1970. Bad entries are dropped.
    static func decode(_ raw: [String: Any]?) -> [String: Date] {
        var runs: [String: Date] = [:]
        for (profile, value) in raw ?? [:] {
            guard let seconds = value as? Double, seconds.isFinite, seconds >= 0 else { continue }
            runs[profile] = Date(timeIntervalSince1970: seconds)
        }
        return runs
    }

    static func encode(_ runs: [String: Date]) -> [String: Double] {
        runs.mapValues(\.timeIntervalSince1970)
    }
}
