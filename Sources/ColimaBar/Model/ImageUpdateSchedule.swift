import Foundation

/// The rules of the image update check. The functions are pure. `ColimaModel`
/// reads the inputs at each tick. The limits protect the anonymous rate limit
/// of Docker Hub (about 10 pulls an hour for each address): each registry
/// call can count as one pull. The Docker Hub budget is global: all profiles,
/// the daily runs and Check Now share it.
enum ImageUpdateSchedule {
    /// A reference is checked at most once in this time.
    static let interval: TimeInterval = 24 * 3600
    /// A run starts at most once in this time, while stale references remain.
    static let runGap: TimeInterval = 3600
    /// An unreachable registry is asked again after this time.
    static let unreachableRetry: TimeInterval = 3600
    /// After a rate limit answer, the registry waits this long.
    static let rateLimitPause: TimeInterval = 6 * 3600
    /// Check Now works once in this time.
    static let checkNowGap: TimeInterval = 5 * 60
    /// The most Docker Hub calls in `hubWindow`, for all profiles together.
    static let hubLimit = 3
    /// The time that the Docker Hub budget looks back.
    static let hubWindow: TimeInterval = 3600
    /// Check Now skips a reference that a check covered in this time.
    static let recentCheck: TimeInterval = 3600
    /// The most references of other registries in one run.
    static let otherLimit = 25
    /// The registry calls that run at the same time.
    static let concurrency = 2
    /// A time further in the future than this is a wrong clock.
    static let futureTolerance: TimeInterval = 24 * 3600

    /// The inputs that the model reads at a tick. All must allow the run.
    /// `recreating` is a VM type change. `checking` is a run that has not ended.
    static func mayRun(
        enabled: Bool, isDebug: Bool, updateRestarting: Bool, running: Bool, hasDockerSocket: Bool,
        busyMarker: String?, actionsInFlight: Int, waking: Bool, transferring: Bool, proxyTransfers: Int,
        trimming: Bool, recreating: Bool, checking: Bool
    ) -> Bool {
        enabled && !isDebug && !updateRestarting && running && hasDockerSocket && busyMarker == nil
            && actionsInFlight == 0 && !waking && !transferring && proxyTransfers == 0 && !trimming && !recreating
            && !checking
    }

    /// True when a run may start: no run yet, or the last one is an hour old.
    /// A last run in the far future is a wrong date: due.
    static func isDue(lastRun: Date?, now: Date) -> Bool {
        guard let lastRun else { return true }
        let age = now.timeIntervalSince(lastRun)
        return age < -futureTolerance || age >= runGap
    }

    /// True when Check Now may run.
    static func checkNowAllowed(last: Date?, now: Date) -> Bool {
        guard let last else { return true }
        let age = now.timeIntervalSince(last)
        return age < -futureTolerance || age >= checkNowGap
    }

    /// How long an entry stays fresh.
    static func freshness(of entry: ImageUpdateCache.Entry) -> TimeInterval {
        switch entry.error {
        case .unreachable: unreachableRetry
        case .rateLimited: rateLimitPause
        default: interval
        }
    }

    /// True when the entry needs a new check. No entry needs one. An entry
    /// from the far future counts as wrong.
    static func isStale(_ entry: ImageUpdateCache.Entry?, now: Date) -> Bool {
        guard let entry else { return true }
        let age = now.timeIntervalSince(entry.date)
        return age < -futureTolerance || age >= freshness(of: entry)
    }

    /// The Docker Hub calls that may start now: the limit minus the calls of
    /// the last hour, and none while Docker Hub waits after a rate limit
    /// answer. A time in the far future is a wrong clock: it counts for nothing.
    static func hubAllowance(_ budget: ImageUpdateCache.HubBudget, now: Date) -> Int {
        let t = now.timeIntervalSince1970
        if let until = budget.pausedUntil, until > t, until - t <= rateLimitPause + futureTolerance { return 0 }
        let recent = budget.calls.filter { $0 > t - hubWindow && $0 <= t + futureTolerance }.count
        return max(hubLimit - recent, 0)
    }

    /// The budget after `count` Docker Hub calls at `now`, and a rate limit
    /// answer if `rateLimited`. It drops the calls that left the window.
    static func hubSpent(
        _ budget: ImageUpdateCache.HubBudget, calls count: Int, rateLimited: Bool, now: Date
    ) -> ImageUpdateCache.HubBudget {
        let t = now.timeIntervalSince1970
        var next = budget
        next.calls = budget.calls.filter { $0 > t - hubWindow && $0 <= t + futureTolerance }
        next.calls += Array(repeating: t, count: count)
        if rateLimited {
            next.pausedUntil = t + rateLimitPause
        } else if let until = budget.pausedUntil, until <= t {
            next.pausedUntil = nil
        }
        return next
    }

    /// The references that one run checks, the oldest check first. A
    /// reference with a fresh entry waits. With `force` (Check Now), a
    /// reference checked in the last hour waits, others do not. Docker Hub
    /// gets what its budget allows. Others get `otherLimit`.
    static func plan(
        refs: [ImageRef], entries: [String: ImageUpdateCache.Entry], hub: ImageUpdateCache.HubBudget, now: Date,
        force: Bool = false
    ) -> [ImageRef] {
        let due = Set(refs).filter { ref in
            let entry = entries[ref.normalized]
            guard force else { return isStale(entry, now: now) }
            guard let entry else { return true }
            let age = now.timeIntervalSince(entry.date)
            return age < -futureTolerance || age >= recentCheck
        }
        let ordered = due.sorted {
            let a = entries[$0.normalized]?.checkedAt ?? 0
            let b = entries[$1.normalized]?.checkedAt ?? 0
            return a != b ? a < b : $0.normalized < $1.normalized
        }
        let hubRefs = ordered.filter(\.isDockerHub).prefix(hubAllowance(hub, now: now))
        let other = ordered.filter { !$0.isDockerHub }.prefix(otherLimit)
        return ordered.filter { hubRefs.contains($0) || other.contains($0) }
    }
}
