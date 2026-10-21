import Foundation
import Network
import os

/// The HTTP proxy of container domains. It listens on 127.0.0.1 and ::1 only.
/// It reads the head of each request, finds the route of its Host and then
/// splices the bytes to `127.0.0.1:<published host port>` (`DomainSession`).
/// A request never starts a VM: a stopped VM gets a 503 page.
///
/// `queue` runs every Network.framework handler and guards the listeners, the
/// sessions and `generation`. `table` has its own `OSAllocatedUnfairLock`.
/// All `NWListener` and `NWConnection` objects are created and used only on
/// `queue`. `@unchecked Sendable` for that reason.
final class DomainProxy: @unchecked Sendable {
    struct Limits: Sendable {
        /// The time for the first request head.
        var headTimeout: TimeInterval = 10
        /// The TCP connect time to the upstream, in seconds.
        var connectTimeout = 5
        /// Each session uses 2 descriptors. `FileLimit` allows 8192.
        var maxSessions = 512
        /// A listener that is not ready in this time counts as failed.
        var readyTimeout: TimeInterval = 2
        /// The time of the connect that finds a busy port.
        var probeTimeout: TimeInterval = 0.3
    }

    /// The only addresses that production binds. The proxy never binds `0.0.0.0` or `::`.
    static let loopbackAddresses = ["127.0.0.1", "::1"]

    let addresses: [String]
    let limits: Limits
    let queue = DispatchQueue(label: "colimabar.domains")
    private let log = Logger(category: "domains")
    private let table = OSAllocatedUnfairLock(initialState: DomainRoutes.empty)
    private let failureHandler = OSAllocatedUnfairLock<(@Sendable () -> Void)?>(initialState: nil)

    // Guarded by `queue`.
    private var listeners: [NWListener] = []
    private var sessions: [ObjectIdentifier: DomainSession] = [:]
    private var generation = 0
    private var boundPort: UInt16?

    init(addresses: [String] = DomainProxy.loopbackAddresses, limits: Limits = .init()) {
        self.addresses = addresses
        self.limits = limits
    }

    /// The routes. A set swaps the whole table. A session reads one snapshot
    /// when it resolves its Host, and a spliced connection keeps its upstream.
    var routes: DomainRoutes {
        get { table.withLock { $0 } }
        set { table.withLock { $0 = newValue } }
    }

    /// Called when a listener fails after it was ready. The proxy has stopped then.
    var onListenerFailure: (@Sendable () -> Void)? {
        get { failureHandler.withLock { $0 } }
        set { failureHandler.withLock { $0 = newValue } }
    }

    /// The port that the proxy listens on, or nil.
    var port: UInt16? { queue.sync { boundPort } }

    var sessionCount: Int { queue.sync { sessions.count } }

    /// The port, for code that already runs on `queue`.
    var portOnQueue: UInt16? { boundPort }

    /// Binds the first candidate that every address accepts. Returns it, or
    /// nil. A call replaces the listeners of an earlier start. `stop()`
    /// while a start runs makes the start return nil with nothing bound.
    func start(candidates: [UInt16]) async -> UInt16? {
        let gen = queue.sync { () -> Int in
            generation += 1
            tearDownListeners()
            return generation
        }
        for candidate in candidates {
            guard queue.sync(execute: { generation == gen }) else { return nil }
            var busy = false
            for address in addresses where !busy {
                busy = await PortProbe.listens(
                    port: Int(candidate), ipv6: address.contains(":"), timeout: limits.probeTimeout)
            }
            if busy {
                log.notice("port \(candidate, privacy: .public) is busy")
                continue
            }
            let bound = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
                queue.async { self.bind(candidate, generation: gen) { cont.resume(returning: $0) } }
            }
            if bound {
                log.notice("listening on port \(candidate, privacy: .public)")
                return candidate
            }
        }
        return nil
    }

    /// Cancels the listeners and every session.
    func stop() {
        queue.sync { stopOnQueue() }
    }

    /// Called by a session, on `queue`, when it ends.
    func sessionEnded(_ session: DomainSession) {
        sessions[ObjectIdentifier(session)] = nil
    }

    // MARK: - Queue only

    private func stopOnQueue() {
        generation += 1
        tearDownListeners()
        let open = Array(sessions.values)
        sessions = [:]
        for s in open { s.cancel() }
    }

    private func tearDownListeners() {
        for l in listeners { l.cancel() }
        listeners = []
        boundPort = nil
    }

    /// What one bind attempt knows. `queue` guards it.
    private final class Attempt: @unchecked Sendable {
        var listeners: [(address: String, listener: NWListener)] = []
        var states: [String: NWListener.State] = [:]
        var unavailable: Set<String> = []
        var done = false
        var timeout: DispatchWorkItem?
    }

    private func bind(_ port: UInt16, generation gen: Int, completion: @escaping @Sendable (Bool) -> Void) {
        guard generation == gen, let endpointPort = NWEndpoint.Port(rawValue: port) else { return completion(false) }
        let attempt = Attempt()

        @Sendable func finish(_ success: Bool) {
            guard !attempt.done else { return }
            attempt.done = true
            attempt.timeout?.cancel()
            if success, generation == gen {
                var held: [NWListener] = []
                for (address, listener) in attempt.listeners {
                    if attempt.unavailable.contains(address) { listener.cancel() } else { held.append(listener) }
                }
                listeners = held
                boundPort = port
                completion(true)
            } else {
                for (_, listener) in attempt.listeners { listener.cancel() }
                completion(false)
            }
        }

        @Sendable func evaluate() {
            guard !attempt.done else { return }
            var ready = 0
            for (address, state) in attempt.states {
                switch state {
                case .ready:
                    ready += 1
                case .failed(let error), .waiting(let error):
                    // A Mac with no IPv6 on lo0 still serves IPv4.
                    guard address.contains(":"), Self.ipv6Unavailable(error) else { return finish(false) }
                    attempt.unavailable.insert(address)
                case .cancelled:
                    return finish(false)
                default:
                    break
                }
            }
            if ready > 0, ready + attempt.unavailable.count == addresses.count { finish(true) }
        }

        for address in addresses {
            attempt.states[address] = .setup
            let tcp = NWProtocolTCP.Options()
            tcp.noDelay = true
            let parameters = NWParameters(tls: nil, tcp: tcp)
            parameters.allowLocalEndpointReuse = true
            (parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options)?.version =
                address.contains(":") ? .v6 : .v4
            parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(address), port: endpointPort)
            guard let listener = try? NWListener(using: parameters) else {
                for (_, l) in attempt.listeners { l.cancel() }
                attempt.done = true
                return completion(false)
            }
            attempt.listeners.append((address, listener))
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                guard let self, let listener else { return }
                if attempt.done {
                    if case .failed = state, listeners.contains(where: { $0 === listener }) { listenerFailed() }
                    return
                }
                attempt.states[address] = state
                evaluate()
            }
            listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
            listener.start(queue: queue)
        }
        let timeout = DispatchWorkItem { finish(false) }
        attempt.timeout = timeout
        queue.asyncAfter(deadline: .now() + limits.readyTimeout, execute: timeout)
    }

    private static func ipv6Unavailable(_ error: NWError) -> Bool {
        if case .posix(let code) = error { return code == .EADDRNOTAVAIL || code == .EAFNOSUPPORT }
        return false
    }

    private func listenerFailed() {
        log.error("a listener failed")
        stopOnQueue()
        onListenerFailure?()
    }

    private func accept(_ connection: NWConnection) {
        guard sessions.count < limits.maxSessions else {
            connection.start(queue: queue)
            connection.send(
                content: DomainPage.response(.busy, headOnly: false),
                completion: .contentProcessed { _ in connection.cancel() })
            return
        }
        let session = DomainSession(client: connection, proxy: self, queue: queue, limits: limits)
        sessions[ObjectIdentifier(session)] = session
        session.start()
    }
}
