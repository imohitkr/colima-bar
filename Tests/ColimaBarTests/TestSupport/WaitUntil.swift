import Foundation

/// Checks `condition` every 10 ms until it is true or `timeout` seconds pass.
/// Returns the last result. Use it instead of a fixed sleep before a check.
func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
    let end = Date().addingTimeInterval(timeout)
    while Date() < end {
        if condition() { return true }
        Thread.sleep(forTimeInterval: 0.01)
    }
    return condition()
}

/// The same for main actor state, from an async test on the main actor. It
/// sleeps without blocking, so main actor tasks run between the checks.
@MainActor
func waitUntil(timeout: TimeInterval = 5, _ condition: @MainActor () -> Bool) async -> Bool {
    let end = Date().addingTimeInterval(timeout)
    while Date() < end {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}
