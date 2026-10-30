import Testing

@testable import ColimaBar

@Suite struct IconCountGateTests {
    private let t0 = ContinuousClock.now
    private func at(_ seconds: Double) -> ContinuousClock.Instant { t0 + .seconds(seconds) }

    private func run(
        _ gate: inout IconCountGate, _ count: Int, at seconds: Double, listed: Int = 1, listable: Bool = true,
        busy: Bool = false
    ) -> IconCountGate.Output {
        gate.update(
            running: true, busy: busy, listed: listed, listable: listable, count: count, now: at(seconds))
    }

    /// A gate that has settled on `count` while the VM runs, at 3 s.
    private func settled(on count: Int) -> IconCountGate {
        var gate = IconCountGate()
        _ = run(&gate, count, at: 0)
        _ = run(&gate, count, at: 3)
        return gate
    }

    @Test func aStoppedVMShowsStopped() {
        var gate = IconCountGate()
        let out = gate.update(running: false, busy: false, listed: 0, listable: true, count: 0, now: t0)
        #expect(out.shown == .stopped)
        #expect(out.digits == 0)
        #expect(out.recheckAt == nil)
    }

    @Test func aStartShowsStartingUntilTheCountSettles() {
        var gate = IconCountGate()
        let first = run(&gate, 3, at: 0)
        #expect(first.shown == .starting)
        #expect(first.recheckAt == at(3))
        #expect(run(&gate, 3, at: 2.9).shown == .starting)
        let last = run(&gate, 3, at: 3)
        #expect(last.shown == .count(3))
        #expect(last.recheckAt == nil)
    }

    @Test func noListYetKeepsStarting() {
        var gate = IconCountGate()
        let first = run(&gate, 0, at: 0, listed: 0)
        #expect(first.shown == .starting)
        #expect(first.recheckAt == at(60))
        #expect(run(&gate, 0, at: 10, listed: 0).shown == .starting)
    }

    @Test func theSettleClockStartsAtTheFirstList() {
        var gate = IconCountGate()
        _ = run(&gate, 0, at: 0, listed: 0)
        let listed = run(&gate, 0, at: 8)
        #expect(listed.shown == .starting)
        #expect(listed.recheckAt == at(11))
        #expect(run(&gate, 0, at: 10.9).shown == .starting)
        #expect(run(&gate, 0, at: 11).shown == .count(0))
    }

    @Test func aStartWithNoContainersShowsZeroAfterTheSettle() {
        var gate = IconCountGate()
        _ = run(&gate, 0, at: 0)
        #expect(run(&gate, 0, at: 2.9).shown == .starting)
        #expect(run(&gate, 0, at: 3).shown == .count(0))
    }

    @Test func batchesOfRestoredContainersShowStartingThenTheFinalCount() {
        var gate = IconCountGate()
        var seen: [IconCountGate.Shown] = []
        // 100 early, then 15, then 100 again, with a change each 2 s.
        for (second, count) in [(0.0, 100), (2, 15), (4, 100), (6, 100), (6.9, 100)] {
            seen.append(run(&gate, count, at: second).shown)
        }
        #expect(seen == [.starting, .starting, .starting, .starting, .starting])
        #expect(run(&gate, 100, at: 7).shown == .count(100))
    }

    @Test func aChangeRestartsTheStartWait() {
        var gate = IconCountGate()
        _ = run(&gate, 100, at: 0)
        let out = run(&gate, 15, at: 2)
        #expect(out.shown == .starting)
        #expect(out.recheckAt == at(5))
    }

    @Test func theStartWaitEndsAfterSixtySeconds() {
        var gate = IconCountGate()
        var count = 1
        var out = run(&gate, count, at: 0)
        // The count changes each 2 s, so it never settles.
        for second in stride(from: 2.0, through: 58, by: 2) {
            count += 1
            out = run(&gate, count, at: second)
            #expect(out.shown == .starting)
        }
        #expect(out.recheckAt == at(60))
        count += 1
        #expect(run(&gate, count, at: 60).shown == .count(count))
    }

    @Test func theLimitEndsTheWaitBeforeALateSettle() {
        var gate = IconCountGate()
        _ = run(&gate, 5, at: 0)
        // A change at 58 puts the settle time after the limit.
        _ = run(&gate, 6, at: 58)
        #expect(run(&gate, 6, at: 59.9).shown == .starting)
        #expect(run(&gate, 6, at: 60).shown == .count(6))
    }

    @Test func theLimitEndsAWaitForAListThatNeverComes() {
        var gate = IconCountGate()
        _ = run(&gate, 0, at: 0, listed: 0)
        #expect(run(&gate, 0, at: 59.9, listed: 0).shown == .starting)
        #expect(run(&gate, 0, at: 60, listed: 0).shown == .count(0))
    }

    @Test func aStopDuringTheStartWaitRestartsTheWait() {
        var gate = IconCountGate()
        _ = run(&gate, 5, at: 0)
        let stop = gate.update(running: false, busy: false, listed: 0, listable: true, count: 0, now: at(5))
        #expect(stop.shown == .stopped)
        // The new start has its own list, settle clock and limit.
        #expect(run(&gate, 0, at: 20, listed: 0).recheckAt == at(80))
        let listed = run(&gate, 7, at: 30)
        #expect(listed.shown == .starting)
        #expect(listed.recheckAt == at(33))
    }

    @Test func aQuickFlapWhileRunningShowsNoChange() {
        var gate = settled(on: 5)
        let up = run(&gate, 6, at: 10)
        #expect(up.shown == .count(5))
        #expect(up.recheckAt == at(11))
        let back = run(&gate, 5, at: 10.5)
        #expect(back.shown == .count(5))
        #expect(back.recheckAt == nil)
        #expect(run(&gate, 5, at: 12).shown == .count(5))
    }

    @Test func aChangeThatLastsOneSecondShows() {
        var gate = settled(on: 5)
        _ = run(&gate, 6, at: 10)
        #expect(run(&gate, 6, at: 10.9).shown == .count(5))
        #expect(run(&gate, 6, at: 11).shown == .count(6))
    }

    @Test func aRiseFromZeroWaitsOneSecond() {
        var gate = settled(on: 0)
        let up = run(&gate, 4, at: 10)
        #expect(up.shown == .count(0))
        #expect(up.recheckAt == at(11))
        #expect(run(&gate, 4, at: 11).shown == .count(4))
    }

    @Test func aSecondChangeRestartsThePendingWait() {
        var gate = settled(on: 5)
        _ = run(&gate, 6, at: 10)
        let second = run(&gate, 7, at: 10.5)
        #expect(second.shown == .count(5))
        #expect(second.recheckAt == at(11.5))
        #expect(run(&gate, 7, at: 11.5).shown == .count(7))
    }

    @Test func aDropToZeroShowsAtOnce() {
        var gate = settled(on: 5)
        let out = run(&gate, 0, at: 10)
        #expect(out.shown == .count(0))
        #expect(out.recheckAt == nil)
    }

    @Test func aStopShowsAtOnceAndTheNextStartWaitsAgain() {
        var gate = settled(on: 5)
        let stop = gate.update(running: false, busy: false, listed: 0, listable: true, count: 5, now: at(10))
        #expect(stop.shown == .stopped)
        #expect(run(&gate, 5, at: 11).shown == .starting)
    }

    @Test func theEndOfAnActionWhileRunningStartsTheWaitAgain() {
        var gate = settled(on: 5)
        _ = run(&gate, 5, at: 10, busy: true)
        let end = run(&gate, 2, at: 12)
        #expect(end.shown == .starting)
        #expect(end.recheckAt == at(72))
        let listed = run(&gate, 2, at: 13, listed: 2)
        #expect(listed.recheckAt == at(16))
        #expect(run(&gate, 2, at: 16, listed: 2).shown == .count(2))
    }

    @Test func theWidestCountKeepsItsDigitsUntilAStop() {
        var gate = IconCountGate()
        _ = run(&gate, 100, at: 0)
        #expect(run(&gate, 100, at: 3).digits == 3)
        _ = run(&gate, 15, at: 10)
        let low = run(&gate, 15, at: 11)
        #expect(low.shown == .count(15))
        #expect(low.digits == 3)
        _ = gate.update(running: false, busy: false, listed: 0, listable: true, count: 0, now: at(20))
        _ = run(&gate, 15, at: 21)
        let again = run(&gate, 15, at: 24)
        #expect(again.shown == .count(15))
        #expect(again.digits == 2)
    }

    @Test func aProfileWithNoDockerSocketHasNoListToWaitFor() {
        var gate = IconCountGate()
        let first = run(&gate, 0, at: 0, listed: 0, listable: false)
        #expect(first.shown == .starting)
        #expect(first.recheckAt == at(3))
        #expect(run(&gate, 0, at: 3, listed: 0, listable: false).shown == .count(0))
    }

    @Test func aListFromBeforeAnActionDoesNotCount() {
        var gate = settled(on: 5)
        _ = run(&gate, 5, at: 10, listed: 4, busy: true)
        let end = run(&gate, 5, at: 12, listed: 4)
        #expect(end.shown == .starting)
        #expect(end.recheckAt == at(72))
        // The same counter value is the old list, a higher one is new.
        #expect(run(&gate, 5, at: 20, listed: 4).shown == .starting)
        let fresh = run(&gate, 5, at: 21, listed: 5)
        #expect(fresh.shown == .starting)
        #expect(fresh.recheckAt == at(24))
        #expect(run(&gate, 5, at: 24, listed: 5).shown == .count(5))
    }

    @Test func theLimitCountsFromTheEndOfAnAction() {
        var gate = IconCountGate()
        _ = run(&gate, 5, at: 0, busy: true)
        let end = run(&gate, 5, at: 10, listed: 0)
        #expect(end.recheckAt == at(70))
        #expect(run(&gate, 5, at: 69.9, listed: 0).shown == .starting)
        #expect(run(&gate, 5, at: 70, listed: 0).shown == .count(5))
    }

    @Test func aBusyVMThatStaysBusyDoesNotStartTheWaitAgain() {
        var gate = settled(on: 5)
        _ = run(&gate, 5, at: 10, busy: true)
        let still = run(&gate, 5, at: 20, busy: true)
        #expect(still.shown == .count(5))
        #expect(still.recheckAt == nil)
    }

    @Test func theStartOfAnActionDoesNotStartTheWaitAgain() {
        var gate = settled(on: 5)
        let begin = run(&gate, 5, at: 10, busy: true)
        #expect(begin.shown == .count(5))
        #expect(begin.recheckAt == nil)
    }

    @Test func theDigitsStayAcrossTheEndOfAnAction() {
        var gate = IconCountGate()
        _ = run(&gate, 100, at: 0)
        _ = run(&gate, 100, at: 3)
        _ = run(&gate, 100, at: 10, busy: true)
        _ = run(&gate, 15, at: 12)
        _ = run(&gate, 15, at: 13, listed: 2)
        let out = run(&gate, 15, at: 16, listed: 2)
        #expect(out.shown == .count(15))
        #expect(out.digits == 3)
    }

    @Test func aDropToZeroDuringTheStartWaitStillWaits() {
        var gate = IconCountGate()
        _ = run(&gate, 5, at: 0)
        let drop = run(&gate, 0, at: 1)
        #expect(drop.shown == .starting)
        #expect(drop.recheckAt == at(4))
        #expect(run(&gate, 0, at: 4).shown == .count(0))
    }

    @Test func aShortFlapToAWiderCountKeepsTheDigits() {
        var gate = settled(on: 5)
        _ = run(&gate, 100, at: 10)
        _ = run(&gate, 5, at: 10.5)
        let out = run(&gate, 5, at: 12)
        #expect(out.shown == .count(5))
        #expect(out.digits == 1)
    }
}
