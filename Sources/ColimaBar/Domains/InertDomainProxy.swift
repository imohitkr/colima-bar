import Foundation
import Network

/// A proxy that binds nothing. A model in a test process uses it when the
/// test gives no other proxy, so a forgotten argument cannot bind a port.
final class InertDomainProxy: DomainProxying, @unchecked Sendable {
    private let lock = NSLock()
    private var table = DomainRoutes.empty
    private var failure: (@Sendable () -> Void)?
    private var httpsFailure: (@Sendable () -> Void)?

    var routes: DomainRoutes {
        get { lock.withLock { table } }
        set { lock.withLock { table = newValue } }
    }

    var onListenerFailure: (@Sendable () -> Void)? {
        get { lock.withLock { failure } }
        set { lock.withLock { failure = newValue } }
    }

    var onHTTPSListenerFailure: (@Sendable () -> Void)? {
        get { lock.withLock { httpsFailure } }
        set { lock.withLock { httpsFailure = newValue } }
    }

    var port: UInt16? { nil }
    var httpsPort: UInt16? { nil }
    func start(candidates: [UInt16]) async -> UInt16? { nil }
    func startHTTPS(candidates: [UInt16], tls: @escaping @Sendable () -> NWProtocolTLS.Options) async -> UInt16? { nil }
    func stop() {}
    func stopHTTPS() {}
    func isFree(port: UInt16) async -> Bool { false }
}
