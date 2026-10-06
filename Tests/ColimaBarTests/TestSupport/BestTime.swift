import Foundation

/// Runs `body` `runs` times and returns the shortest duration.
///
/// Other suites run in parallel and can slow down one run. The shortest run
/// is the closest to the real cost, so a time bound in a test stays stable.
func bestTime(runs: Int = 3, _ body: () -> Void) -> Duration {
    var best = Duration.seconds(3600)
    for _ in 0..<max(runs, 1) {
        let start = ContinuousClock.now
        body()
        best = min(best, ContinuousClock.now - start)
    }
    return best
}
