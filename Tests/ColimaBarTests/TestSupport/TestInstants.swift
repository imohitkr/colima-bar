import Foundation

/// A suspending clock that a test moves forward by hand.
struct TestInstants {
    let start = SuspendingClock.now
    var now: SuspendingClock.Instant { start + elapsed }
    private var elapsed = Duration.zero
    mutating func advance(_ seconds: Int) { elapsed += .seconds(seconds) }
}
