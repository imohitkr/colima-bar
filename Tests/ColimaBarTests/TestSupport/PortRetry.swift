import Foundation

/// Starts a listener on a port that was free a moment ago. Another process
/// can take the port before the bind, so a start that fails gets a fresh port.
enum PortRetry {
    /// Calls `bind` with a new unused port until it returns a bound port, at most `attempts` times.
    static func start(attempts: Int = 3, _ bind: (UInt16) async -> UInt16?) async throws -> UInt16 {
        for _ in 0..<attempts {
            let port = UInt16(try LoopbackListener.unusedPort())
            if let bound = await bind(port) { return bound }
        }
        throw POSIXError(.EADDRINUSE)
    }
}
