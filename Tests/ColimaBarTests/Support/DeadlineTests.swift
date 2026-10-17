import Foundation
import Testing

@testable import ColimaBar

/// A gate that holds a task without polling. A task that waits on it ignores
/// a cancel, like `Shell.run`.
private final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var open = false
    private var waiter: CheckedContinuation<Void, Never>?

    func wait() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            let resumeNow = lock.withLock { () -> Bool in
                if open { return true }
                waiter = cont
                return false
            }
            if resumeNow { cont.resume() }
        }
    }

    func release() {
        let w = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            open = true
            defer { waiter = nil }
            return waiter
        }
        w?.resume()
    }
}

@Suite struct DeadlineTests {
    @Test func aFastOperationGivesItsValue() async {
        let v = await Deadline.run(seconds: 60, fallback: "late") { "done" }
        #expect(v == "done")
    }

    @Test func anOperationThatNeverEndsGivesTheFallback() async {
        let v = await Deadline.run(seconds: 0, fallback: "late") {
            // A long sleep that a cancel ends: the test leaves no task behind.
            try? await Task.sleep(for: .seconds(3600))
            return "never"
        }
        #expect(v == "late")
    }

    @Test func anOperationThatIgnoresACancelDoesNotHoldTheCaller() async {
        let gate = Gate()
        let v = await Deadline.run(seconds: 0, fallback: 0) {
            // Like Shell.run: a cancel does not end the wait. Only the gate does.
            await gate.wait()
            return 1
        }
        #expect(v == 0)
        gate.release()
    }

    @Test func aFastOperationWithALongDeadlineReturnsAtOnce() async {
        // The timer task must not hold the caller. A 1 hour deadline would show it.
        let v = await Deadline.run(seconds: 3600, fallback: 0) { 7 }
        #expect(v == 7)
    }
}
