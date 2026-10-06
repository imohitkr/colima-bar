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
