import Darwin
import Foundation

/// Short, unique paths for test sockets.
///
/// sun_path holds only 104 bytes, so the paths stay short. Each call gives a
/// new path, because Swift Testing runs suites in parallel and `.serialized`
/// applies only to the tests of one suite.
enum TestSocketPath {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var last = 0

    /// For example "/tmp/cb-4242-7-k3x9.sock".
    static func unique() -> String {
        let n = lock.withLock {
            last += 1
            return last
        }
        let tag = String(UInt32.random(in: 0..<(36 * 36 * 36 * 36)), radix: 36)
        return "/tmp/cb-\(getpid())-\(n)-\(tag).sock"
    }
}
