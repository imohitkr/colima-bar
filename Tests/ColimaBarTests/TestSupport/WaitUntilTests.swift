import Foundation
import Testing

@Suite struct WaitUntilTests {
    private let start = ContinuousClock.now

    @Test func aLateWakeMovesTheEndOut() {
        var budget = WaitBudget(start: start, timeout: 20)
        budget.noteWake(late: .seconds(3))
        #expect(budget.hasTime(at: start + .seconds(22.9)))
        #expect(!budget.hasTime(at: start + .seconds(23.1)))
    }

    @Test func aWakeWithinAFewMillisecondsCostsNothing() {
        var budget = WaitBudget(start: start, timeout: 20)
        budget.noteWake(late: .milliseconds(4))
        budget.noteWake(late: WaitBudget.stallThreshold)
        #expect(!budget.hasTime(at: start + .seconds(20.001)))
    }

    @Test func stallsNeverMoveTheEndPastTheAllowance() {
        var budget = WaitBudget(start: start, timeout: 20)
        for _ in 0..<1_000 { budget.noteWake(late: .seconds(30)) }
        #expect(budget.hasTime(at: start + .seconds(119)))
        #expect(!budget.hasTime(at: start + .seconds(121)))
    }

    // The bound in time is tested on WaitBudget above: a stalled runner would
    // make a wall-clock check of this wait fail for no fault of the code.
    @Test func aConditionThatNeverComesFails() async {
        #expect(await !waitUntil(timeout: 0.2) { false })
    }

    @Test func aConditionThatBecomesTrueEndsTheWait() async {
        let calls = Counter()
        let ok = await waitUntil(timeout: 5) {
            calls.add()
            return calls.value == 3
        }
        #expect(ok)
    }
}
