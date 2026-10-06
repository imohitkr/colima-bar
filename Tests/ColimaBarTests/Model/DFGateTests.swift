import Foundation
import Testing

@testable import ColimaBar

@Suite struct DFGateTests {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    /// Each call returns the step, so #expect does not capture `g` (it must mutate).
    private func ask(_ g: inout DFGate, at s: TimeInterval, urgent: Bool = false) -> DFGate.Step {
        g.request(now: t0.addingTimeInterval(s), urgent: urgent)
    }

    private func done(_ g: inout DFGate, at s: TimeInterval) -> DFGate.Step { g.end(now: t0.addingTimeInterval(s)) }

    @Test func firstRequestRunsNowAndOthersJoinIt() {
        var g = DFGate()
        var steps = [ask(&g, at: 0), ask(&g, at: 0)]  // the second is already scheduled
        g.begin()
        steps += [ask(&g, at: 0), ask(&g, at: 0)]  // in flight: remembered
        // Requests during the run join into one more run after the gap.
        steps += [done(&g, at: 5), ask(&g, at: 6)]
        #expect(steps == [.run(after: 0), .none, .none, .none, .run(after: 30), .none])
    }

    @Test func noRequestDuringTheRunMeansNoRerun() {
        var g = DFGate()
        _ = ask(&g, at: 0)
        g.begin()
        let step = done(&g, at: 0)
        #expect(step == .none)
        #expect(!g.scheduled && !g.inFlight)
    }

    @Test func waitsForTheRestOfTheGap() {
        var g = DFGate()
        _ = ask(&g, at: 0)
        g.begin()
        _ = done(&g, at: 0)
        let first = ask(&g, at: 10)
        g.begin()
        _ = done(&g, at: 30)
        let second = ask(&g, at: 65)
        #expect(first == .run(after: 20))
        #expect(second == .run(after: 0))
    }

    @Test func skipAllowsALaterRequest() {
        var g = DFGate()
        _ = ask(&g, at: 0)
        g.skip()  // the tab closed during the wait
        let step = ask(&g, at: 0)
        #expect(step == .run(after: 0))
    }

    @Test func urgentSkipsTheGap() {
        var g = DFGate()
        _ = ask(&g, at: 0)
        g.begin()
        _ = done(&g, at: 1)
        let step = ask(&g, at: 2, urgent: true)
        #expect(step == .run(after: 0))
    }

    @Test func urgentReplacesAWaitingRun() {
        var g = DFGate()
        _ = ask(&g, at: 0)
        g.begin()
        _ = done(&g, at: 1)
        let normal = ask(&g, at: 2)
        let waiting = g.ticket
        let urgent = ask(&g, at: 3, urgent: true)
        #expect(normal == .run(after: 29))
        #expect(urgent == .run(after: 0))
        #expect(g.ticket != waiting, "the waiting run must see that it was replaced")
        // Another normal request joins the urgent run.
        let joined = ask(&g, at: 3)
        #expect(joined == .none)
    }

    @Test func urgentWaitsForTheRunInFlightThenRunsAtOnce() {
        var g = DFGate()
        _ = ask(&g, at: 0)
        g.begin()
        let during = ask(&g, at: 1, urgent: true)
        let after = done(&g, at: 5)
        #expect(during == .none)  // only one df in flight
        #expect(after == .run(after: 0))  // no 30 s gap
    }

    @Test func normalRequestDuringARunStillWaitsForTheGap() {
        var g = DFGate()
        _ = ask(&g, at: 0)
        g.begin()
        _ = ask(&g, at: 1)
        let after = done(&g, at: 5)
        #expect(after == .run(after: 30))
    }

    @Test func skipForgetsAnUrgentRequest() {
        var g = DFGate()
        _ = ask(&g, at: 0)
        g.begin()
        _ = ask(&g, at: 1, urgent: true)
        g.skip()
        #expect(!g.again && !g.againUrgent)
    }
}
