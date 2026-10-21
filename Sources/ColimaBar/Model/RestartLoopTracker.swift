import Foundation

/// Counts the unexpected exits of each container, to find a restart loop.
/// The caller passes the time, so the tests need no clock.
struct RestartLoopTracker: Sendable {
    /// This many exits ...
    static let threshold = 3
    /// ... in this time are a loop.
    static let window: TimeInterval = 5 * 60
    /// A container that runs this long without an exit ends its loop.
    static let stableAfter: TimeInterval = 10 * 60
    /// The table keeps at most this many ids before it drops the old ones.
    private static let pruneAbove = 200

    enum Verdict: Equatable, Sendable {
        /// One exit in the window.
        case first
        /// The second exit, below the threshold.
        case repeated
        /// The exit that reaches the threshold: the one notice.
        case loopStarted(count: Int)
        /// An exit while in a loop: silent.
        case stillLooping
    }

    private struct Entry {
        var exits: [Date]
        var last: Date
        var looping: Bool
        /// A crash alert went out since the window of exits began.
        var alertedCrash = false
    }

    private var entries: [String: Entry] = [:]

    mutating func recordExit(id: String, now: Date) -> Verdict {
        if entries.count > Self.pruneAbove {
            entries = entries.filter { now.timeIntervalSince($0.value.last) < Self.stableAfter }
        }
        var entry = entries[id] ?? Entry(exits: [], last: now, looping: false)
        // A loop ends lazily: no timer runs.
        if now.timeIntervalSince(entry.last) >= Self.stableAfter { entry = Entry(exits: [], last: now, looping: false) }
        entry.exits.removeAll { now.timeIntervalSince($0) > Self.window }
        if entry.exits.isEmpty { entry.alertedCrash = false }
        entry.exits.append(now)
        entry.last = now
        let verdict: Verdict
        if entry.looping {
            verdict = .stillLooping
        } else if entry.exits.count >= Self.threshold {
            entry.looping = true
            verdict = .loopStarted(count: entry.exits.count)
        } else {
            verdict = entry.exits.count == 1 ? .first : .repeated
        }
        entries[id] = entry
        return verdict
    }

    /// False once `within` passed since the last exit. The default is
    /// `stableAfter`, the time a loop needs to end by itself.
    func isLooping(id: String, now: Date, within: TimeInterval = stableAfter) -> Bool {
        guard let entry = entries[id], entry.looping else { return false }
        return now.timeIntervalSince(entry.last) < within
    }

    /// How many exits in the last `within` seconds. The next exit makes one more.
    func exitCount(id: String, now: Date, within: TimeInterval) -> Int {
        entries[id]?.exits.filter { now.timeIntervalSince($0) <= within }.count ?? 0
    }

    /// A healthy container is no loop. The next exit counts as a new first one.
    mutating func endLoop(id: String) {
        guard entries[id]?.looping == true else { return }
        entries[id] = nil
    }

    /// True if a crash alert already went out in this window of exits.
    func crashAlerted(id: String) -> Bool { entries[id]?.alertedCrash ?? false }

    /// Call it after `recordExit`, when the crash alert goes out.
    mutating func markCrashAlerted(id: String) {
        entries[id]?.alertedCrash = true
    }

    var entryCount: Int { entries.count }

    /// For a `destroy` event.
    mutating func forget(id: String) {
        entries[id] = nil
    }
}
