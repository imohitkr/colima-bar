import Foundation

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

    var routes: DomainRoutes {
        get { lock.withLock { table } }
        set { lock.withLock { table = newValue } }
    }

    var onListenerFailure: (@Sendable () -> Void)? {
        get { lock.withLock { failure } }
        set { lock.withLock { failure = newValue } }
    }

    var port: UInt16? { lock.withLock { bound } }

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
