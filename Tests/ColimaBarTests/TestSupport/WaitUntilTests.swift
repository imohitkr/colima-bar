import Foundation
import Testing

@Suite struct WaitUntilTests {
    private let start = Date(timeIntervalSince1970: 1_000)

    @Test func aLateWakeMovesTheEndOut() {
        var budget = WaitBudget(start: start, timeout: 20)
        budget.noteWake(late: 3)
        #expect(budget.hasTime(at: start.addingTimeInterval(22.9)))
        #expect(!budget.hasTime(at: start.addingTimeInterval(23.1)))
    }

    @Test func aWakeWithinAFewMillisecondsCostsNothing() {
        var budget = WaitBudget(start: start, timeout: 20)
        budget.noteWake(late: 0.004)
        budget.noteWake(late: WaitBudget.stallThreshold)
        #expect(!budget.hasTime(at: start.addingTimeInterval(20.001)))
    }

    @Test func stallsNeverMoveTheEndPastTheAllowance() {
        var budget = WaitBudget(start: start, timeout: 20)
        for _ in 0..<1_000 { budget.noteWake(late: 30) }
        #expect(budget.hasTime(at: start.addingTimeInterval(119)))
        #expect(!budget.hasTime(at: start.addingTimeInterval(121)))
    }

    @Test func aConditionThatNeverComesEndsAtTheTimeout() async {
        let began = Date()
        let ok = await waitUntil(timeout: 0.2) { false }
        #expect(!ok)
        #expect(Date().timeIntervalSince(began) < 5)
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
