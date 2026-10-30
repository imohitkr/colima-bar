/// Decides which count the menu bar icon shows. After a start, Docker restores
/// the containers in batches, so the running count jumps up and down. The gate
/// waits for the count to settle. It holds no timer: the caller passes the time
/// and runs the next check at `recheckAt`.
struct IconCountGate {
    /// What the icon shows for the profile.
    enum Shown: Equatable {
        /// The VM is not running.
        case stopped
        /// The VM runs and the count has not settled yet.
        case starting
        case count(Int)
    }

    struct Output: Equatable {
        let shown: Shown
        /// The widest count shown since the VM started, in digits.
        let digits: Int
        /// When the caller must call `update` again, if nothing else changes.
        let recheckAt: ContinuousClock.Instant?
    }

    /// After a start, the count must stay the same this long.
    static let startSettle = Duration.seconds(3)
    /// The start wait lasts this long at most. The time counts from the start
    /// of the wait: the first sight of a running VM, or the end of an action.
    static let startLimit = Duration.seconds(60)
    /// While the VM runs, a changed count must stay this long.
    static let changeSettle = Duration.seconds(1)

    private enum Phase {
        /// The VM has not been seen running.
        case idle
        /// The VM runs. The wait ends at `limit`. The count must have a list
        /// newer than `base` and then stay the same from `settleFrom`.
        case starting(limit: ContinuousClock.Instant, base: Int, settleFrom: ContinuousClock.Instant?)
        /// The VM runs. The count shown is `settled`.
        case running(changedAt: ContinuousClock.Instant)
    }

    private var phase = Phase.idle
    private var wasBusy = false
    private var digits = 0
    /// The newest count.
    private var latest = 0
    /// The count that the icon shows while the VM runs.
    private var settled = 0

    /// `listed` counts the container lists read since the VM started.
    /// `listable` is false for a profile with no docker socket: it has no
    /// list to wait for. `busy` is true while an action runs; the end of an
    /// action starts the wait again, because a restart may never show a stop.
    /// A list from before that action does not count.
    /// A stop shows at once. A count of 0 shows at once after the start wait.
    /// Any other change waits.
    mutating func update(
        running: Bool, busy: Bool, listed: Int, listable: Bool, count: Int,
        now: ContinuousClock.Instant
    ) -> Output {
        guard running else {
            self = IconCountGate()
            return Output(shown: .stopped, digits: 0, recheckAt: nil)
        }
        let actionEnded = wasBusy && !busy
        wasBusy = busy
        if actionEnded {
            phase = .starting(limit: now + Self.startLimit, base: listed, settleFrom: nil)
        }
        switch phase {
        case .idle:
            // A start clears the counter, so the first list is above 0.
            phase = .starting(limit: now + Self.startLimit, base: 0, settleFrom: nil)
            return update(
                running: running, busy: busy, listed: listed, listable: listable, count: count, now: now)
        case .starting(let limit, let base, var settleFrom):
            if !listable || listed > base, settleFrom == nil || count != latest {
                latest = count
                settleFrom = now
            }
            phase = .starting(limit: limit, base: base, settleFrom: settleFrom)
            let settleAt = settleFrom.map { $0 + Self.startSettle }
            guard now >= limit || settleAt.map({ now >= $0 }) == true else {
                return Output(shown: .starting, digits: digits, recheckAt: min(settleAt ?? limit, limit))
            }
            phase = .running(changedAt: now)
            latest = count
            return shown(count)
        case .running(var changedAt):
            if count != latest {
                latest = count
                changedAt = now
                phase = .running(changedAt: now)
            }
            if count == settled || count == 0 || now - changedAt >= Self.changeSettle {
                return shown(count)
            }
            return Output(shown: .count(settled), digits: digits, recheckAt: changedAt + Self.changeSettle)
        }
    }

    private mutating func shown(_ count: Int) -> Output {
        settled = count
        if count > 0 { digits = max(digits, String(count).count) }
        return Output(shown: .count(count), digits: digits, recheckAt: nil)
    }
}
