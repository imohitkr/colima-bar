import Foundation

/// A proxy that binds nothing. A model in a test process uses it when the
/// test gives no other proxy, so a forgotten argument cannot bind a port.
final class InertDomainProxy: DomainProxying, @unchecked Sendable {
    private let lock = NSLock()
    private var table = DomainRoutes.empty
    private var failure: (@Sendable () -> Void)?

    var routes: DomainRoutes {
        get { lock.withLock { table } }
        set { lock.withLock { table = newValue } }
    }

    var onListenerFailure: (@Sendable () -> Void)? {
        get { lock.withLock { failure } }
        set { lock.withLock { failure = newValue } }
    }

    var port: UInt16? { nil }
    func start(candidates: [UInt16]) async -> UInt16? { nil }
    func stop() {}
    func isFree(port: UInt16) async -> Bool { false }
}
