import Foundation

/// A thread-safe counter, for example of wake() calls.
/// `@unchecked Sendable`: `lock` guards `n`.
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func add() { lock.withLock { n += 1 } }
    var value: Int { lock.withLock { n } }
}
