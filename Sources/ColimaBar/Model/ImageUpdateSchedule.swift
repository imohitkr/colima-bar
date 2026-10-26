import Foundation

/// The rules of the image update check. The functions are pure. `ColimaModel`
/// reads the inputs at each tick. The limits protect the anonymous rate limit
/// of Docker Hub (about 10 pulls an hour for each address): each registry
/// call can count as one pull.
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
    /// The most Docker Hub references of one run.
    static let hubLimit = 3
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

    /// True while Docker Hub waits after a rate limit answer. Any entry of
    /// Docker Hub can carry it.
    static func hubPaused(entries: [String: ImageUpdateCache.Entry], now: Date) -> Bool {
        entries.contains { key, entry in
            key.hasPrefix(ImageRef.hub + "/") && entry.error == .rateLimited
                && (-futureTolerance..<rateLimitPause).contains(now.timeIntervalSince(entry.date))
        }
    }

    /// The references that one run checks, the oldest check first. A
    /// reference with a fresh entry waits, unless `force`. Docker Hub gets at
    /// most `hubLimit` and waits while it is paused. Others get `otherLimit`.
    static func plan(
        refs: [ImageRef], entries: [String: ImageUpdateCache.Entry], now: Date, force: Bool = false
    ) -> [ImageRef] {
        let paused = hubPaused(entries: entries, now: now)
        let due = Set(refs).filter { force || isStale(entries[$0.normalized], now: now) }
        let ordered = due.sorted {
            let a = entries[$0.normalized]?.checkedAt ?? 0
            let b = entries[$1.normalized]?.checkedAt ?? 0
            return a != b ? a < b : $0.normalized < $1.normalized
        }
        let hub = paused ? [] : ordered.filter(\.isDockerHub).prefix(hubLimit)
        let other = ordered.filter { !$0.isDockerHub }.prefix(otherLimit)
        return ordered.filter { hub.contains($0) || other.contains($0) }
    }
}
