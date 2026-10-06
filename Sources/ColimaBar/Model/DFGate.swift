import Foundation

/// Decides when the next `/system/df` runs. At most one runs at a time, and
/// a new one starts at least `minGap` after the last one ended. Requests that
/// come in meanwhile join into one more run after the gap. An urgent request
/// skips the gap, but it still waits for the run in flight.
struct DFGate {
    enum Step: Equatable {
        case none
        case run(after: TimeInterval)
    }

    var minGap: TimeInterval = 30
    private(set) var scheduled = false  // a run waits for the gap or is in flight
    private(set) var inFlight = false
    private(set) var again = false  // requested while a run was in flight
    private(set) var againUrgent = false  // an urgent request came while a run was in flight
    private(set) var lastEnd: Date?
    /// Bumps each time a run is scheduled. A waiting run whose ticket is no
    /// longer current was replaced by an urgent run and must not start.
    private(set) var ticket = 0

    mutating func request(now: Date, urgent: Bool = false) -> Step {
        if inFlight {
            again = true
            if urgent { againUrgent = true }
            return .none
        }
        // The waiting run covers a normal request. An urgent one replaces it.
        if scheduled, !urgent { return .none }
        scheduled = true
        ticket += 1
        let wait = urgent ? 0 : lastEnd.map { max(0, minGap - now.timeIntervalSince($0)) } ?? 0
        return .run(after: wait)
    }

    mutating func begin() { inFlight = true }

    /// Call when the run ends (with or without data). Returns the run that
    /// covers requests made while it was in flight.
    mutating func end(now: Date) -> Step {
        inFlight = false
        scheduled = false
        lastEnd = now
        guard again else { return .none }
        let urgent = againUrgent
        again = false
        againUrgent = false
        return request(now: now, urgent: urgent)
    }

    /// The waiting run did not start because nothing shows the data now.
    mutating func skip() {
        scheduled = false
        again = false
        againUrgent = false
    }
}
