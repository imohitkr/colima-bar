import Foundation

/// The time that `waitUntil` still has. A sleep that wakes up late shows that
/// the runner did not run the task, and that time does not count.
/// It uses the continuous clock, so a change of the wall clock moves nothing.
struct WaitBudget {
    typealias Instant = ContinuousClock.Instant
    private(set) var end: Instant
    private let latest: Instant

    /// A free runner wakes a task within a few ms. Later than this is a stall.
    static let stallThreshold: Duration = .milliseconds(50)
    /// A stall can move the end out to this many times `timeout`, no further.
    static let stallAllowance = 6.0

    init(start: Instant = .now, timeout: TimeInterval) {
        end = start + .seconds(timeout)
        latest = start + .seconds(timeout * Self.stallAllowance)
    }

    func hasTime(at now: Instant = .now) -> Bool { now < end }

    /// `late` is how long the sleep took beyond its length.
    mutating func noteWake(late: Duration) {
        if late > Self.stallThreshold { end = min(end + late, latest) }
    }
}

/// Checks `condition` every 10 ms until it is true or `timeout` seconds pass.
/// Returns the last result. Use it instead of a fixed sleep before a check.
/// It sleeps without blocking, so other tasks (main actor tasks too) run
/// between the checks. `condition` runs in the isolation of the caller.
///
/// The timeout is a liveness limit: only a test that hangs reaches it. The
/// whole test run shares the cores of a CI runner (3 on a hosted Mac), and
/// thousands of tests that start together can keep a test from running for
/// 20 s or more. That is no hang, so the time of a late wake-up does not count
/// (see `WaitBudget`). A hang still ends the test, after at most 6 times
/// `timeout`.
func waitUntil(
    timeout: TimeInterval = 20, isolation: isolated (any Actor)? = #isolation, _ condition: () -> Bool
) async -> Bool {
    let step = Duration.milliseconds(10)
    var budget = WaitBudget(timeout: timeout)
    while budget.hasTime() {
        if condition() { return true }
        let before = ContinuousClock.now
        try? await Task.sleep(for: step)
        budget.noteWake(late: ContinuousClock.now - before - step)
    }
    return condition()
}
