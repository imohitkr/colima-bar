import Foundation

/// Checks `condition` every 10 ms until it is true or `timeout` seconds pass.
/// Returns the last result. Use it instead of a fixed sleep before a check.
/// It sleeps without blocking, so other tasks (main actor tasks too) run
/// between the checks. `condition` runs in the isolation of the caller.
/// The 20 s default is a liveness limit: a slow CI runner can stall for
/// seconds, and only a test that hangs reaches it.
func waitUntil(
    timeout: TimeInterval = 20, isolation: isolated (any Actor)? = #isolation, _ condition: () -> Bool
) async -> Bool {
    let end = Date().addingTimeInterval(timeout)
    while Date() < end {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}
