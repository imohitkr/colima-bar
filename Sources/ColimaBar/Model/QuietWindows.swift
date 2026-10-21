import Foundation

/// The times in which a container alert is no news: after a stop signal,
/// during a VM-wide action and in the first minutes after a start.
struct QuietWindows: Sendable {
    /// A `die` this long after a stop signal is an expected stop. A long
    /// `stop_grace_period` fits.
    static let expectedStop: TimeInterval = 120
    /// An unhealthy alert waits this long after a start.
    static let startGrace: TimeInterval = 180
    /// The hold lasts this long after a VM-wide action ends.
    static let holdTail: TimeInterval = 30
    /// A `die` this long after any other signal is an expected stop too: a
    /// container can have its own STOPSIGNAL.
    static let otherSignal: TimeInterval = 15
    /// The signals of a stop: SIGHUP, SIGINT, SIGQUIT, SIGKILL and SIGTERM.
    private static let stopSignals: Set<String> = ["1", "2", "3", "9", "15"]
    private static let pruneAbove = 200

    private var killUntil: [String: Date] = [:]
    private var startedAt: [String: Date] = [:]
    private var holdDepth = 0
    private var holdUntil = Date.distantPast

    /// The `kill` event of dockerd comes before the `die` of `docker stop`,
    /// `docker restart` and `docker compose`. An OOM kill sends no `kill` event.
    /// A stop signal opens the long window, any other signal the short one.
    mutating func noteKill(id: String, signal: String?, now: Date) {
        if killUntil.count > Self.pruneAbove { killUntil = killUntil.filter { $0.value > now } }
        let length = signal.map(Self.stopSignals.contains) == true ? Self.expectedStop : Self.otherSignal
        let until = now.addingTimeInterval(length)
        // A short window never cuts a long one.
        killUntil[id] = max(killUntil[id] ?? .distantPast, until)
    }

    /// A start ends the stop window: a crash right after a restart is a crash.
    mutating func noteStart(id: String, now: Date) {
        killUntil[id] = nil
        if startedAt.count > Self.pruneAbove {
            startedAt = startedAt.filter { now.timeIntervalSince($0.value) < Self.startGrace }
        }
        startedAt[id] = now
    }

    mutating func holdAll() {
        holdDepth += 1
    }

    mutating func releaseAll(now: Date) {
        guard holdDepth > 0 else { return }
        holdDepth = max(0, holdDepth - 1)
        if holdDepth == 0 { holdUntil = now.addingTimeInterval(Self.holdTail) }
    }

    /// True while a VM-wide action runs, and for `holdTail` after it.
    func isHeld(now: Date) -> Bool {
        holdDepth > 0 || now < holdUntil
    }

    /// The seconds until the hold ends. While an action runs its end is not
    /// known, so this gives the tail: look again after it.
    func holdLeft(now: Date) -> TimeInterval {
        if holdDepth > 0 { return Self.holdTail }
        return max(0, holdUntil.timeIntervalSince(now))
    }

    func stopIsExpected(id: String, now: Date) -> Bool {
        if isHeld(now: now) { return true }
        guard let until = killUntil[id] else { return false }
        return now < until
    }

    /// The seconds that remain of the start grace, 0 if none.
    func startGraceLeft(id: String, now: Date) -> TimeInterval {
        guard let start = startedAt[id] else { return 0 }
        return max(0, Self.startGrace - now.timeIntervalSince(start))
    }

    var entryCount: Int { killUntil.count + startedAt.count }

    mutating func forget(id: String) {
        killUntil[id] = nil
        startedAt[id] = nil
    }
}
