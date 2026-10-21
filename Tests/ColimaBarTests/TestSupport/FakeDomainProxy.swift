import Foundation
import Network

@testable import ColimaBar

/// A stand-in for `DomainProxy` in model tests. It binds nothing. A test sets
/// which ports are busy and reads which candidates the model tried.
/// `@unchecked Sendable`: `lock` guards the state.
final class FakeDomainProxy: DomainProxying, @unchecked Sendable {
    private let lock = NSLock()
    private var table = DomainRoutes.empty
    private var failure: (@Sendable () -> Void)?
    private var bound: UInt16?
    private var busy: Set<UInt16> = []
    private var calls: [[UInt16]] = []
    private var stopCount = 0
    private var hook: (@Sendable ([UInt16]) async -> Void)?
    private var httpsFailure: (@Sendable () -> Void)?
    private var httpsBound: UInt16?
    private var httpsBusy: Set<UInt16> = []
    private var httpsCalls: [[UInt16]] = []
    private var httpsStopCount = 0

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

    var port: UInt16? { lock.withLock { bound } }
    var httpsPort: UInt16? { lock.withLock { httpsBound } }

    /// The HTTPS ports that something else listens on.
    var busyHTTPSPorts: Set<UInt16> {
        get { lock.withLock { httpsBusy } }
        set { lock.withLock { httpsBusy = newValue } }
    }

    /// The candidates of each `startHTTPS` call, in order.
    var httpsStarts: [[UInt16]] { lock.withLock { httpsCalls } }
    var httpsStops: Int { lock.withLock { httpsStopCount } }

    func startHTTPS(candidates: [UInt16], tls: @escaping @Sendable () -> NWProtocolTLS.Options) async -> UInt16? {
        lock.withLock {
            httpsCalls.append(candidates)
            httpsBound = nil
            return candidates.first(where: { !httpsBusy.contains($0) }).map { pick in
                httpsBound = pick
                return pick
            }
        }
    }

    func stopHTTPS() {
        lock.withLock {
            httpsStopCount += 1
            httpsBound = nil
        }
    }

    /// The HTTPS listener fails after it was ready.
    func failHTTPSListener() {
        let handler = lock.withLock { () -> (@Sendable () -> Void)? in
            httpsBound = nil
            return httpsFailure
        }
        handler?()
    }

    /// The ports that something else listens on.
    var busyPorts: Set<UInt16> {
        get { lock.withLock { busy } }
        set { lock.withLock { busy = newValue } }
    }

    /// The candidates of each `start` call, in order.
    var starts: [[UInt16]] { lock.withLock { calls } }
    var stops: Int { lock.withLock { stopCount } }

    /// Runs at the start of each `start` call, before it picks a port.
    func onStart(_ body: (@Sendable ([UInt16]) async -> Void)?) { lock.withLock { hook = body } }

    func start(candidates: [UInt16]) async -> UInt16? {
        let run = lock.withLock { () -> (@Sendable ([UInt16]) async -> Void)? in
            calls.append(candidates)
            bound = nil
            return hook
        }
        await run?(candidates)
        return lock.withLock {
            guard let pick = candidates.first(where: { !busy.contains($0) }) else { return nil }
            bound = pick
            return pick
        }
    }

    func stop() {
        lock.withLock {
            stopCount += 1
            bound = nil
            httpsBound = nil
        }
    }

    func isFree(port: UInt16) async -> Bool { lock.withLock { !busy.contains(port) } }

    /// The listener fails after it was ready: the proxy has stopped.
    func failListener() {
        let handler = lock.withLock { () -> (@Sendable () -> Void)? in
            bound = nil
            return failure
        }
        handler?()
    }
}
