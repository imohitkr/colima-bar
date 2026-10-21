import Foundation
import Network
import os

/// What the model needs from the proxy. The tests give the model a fake.
protocol DomainProxying: AnyObject, Sendable {
    var routes: DomainRoutes { get set }
    var onListenerFailure: (@Sendable () -> Void)? { get set }
    /// Called when the HTTPS listener fails after it was ready. Only HTTPS has stopped then.
    var onHTTPSListenerFailure: (@Sendable () -> Void)? { get set }
    var port: UInt16? { get }
    var httpsPort: UInt16? { get }
    func start(candidates: [UInt16]) async -> UInt16?
    /// Like `start`, for the HTTPS listener. `tls` makes the TLS options of one listener.
    func startHTTPS(candidates: [UInt16], tls: @escaping @Sendable () -> NWProtocolTLS.Options) async -> UInt16?
    /// Stops the HTTP and the HTTPS listener, and every session.
    func stop()
    /// Stops the HTTPS listener and its sessions. The HTTP listener stays.
    func stopHTTPS()
    /// True when nothing on this Mac accepts connections on `port`.
    func isFree(port: UInt16) async -> Bool
}

/// The proxy of container domains. It listens on 127.0.0.1 and ::1 only, with
/// an HTTP listener and, when HTTPS is on, a TLS listener of its own. Each
/// listener (a `Front`) has its own port, start generation and close wait.
/// It reads the head of each request, finds the route of its Host and then
/// splices the bytes to `127.0.0.1:<published host port>` (`DomainSession`).
/// A request never starts a VM: a stopped VM gets a 503 page.
///
/// `queue` runs every Network.framework handler and guards the listeners, the
/// sessions and `generation`. `table` has its own `OSAllocatedUnfairLock`.
/// All `NWListener` and `NWConnection` objects are created and used only on
/// `queue`. `@unchecked Sendable` for that reason.
final class DomainProxy: DomainProxying, @unchecked Sendable {
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
        /// How long `start` waits for the old listeners to close.
        var closeTimeout: TimeInterval = 1
        /// How long a connection that got an error page stays open to read the rest of the request.
        var pageGrace: TimeInterval = 1
    }

    /// The only addresses that production binds. The proxy never binds `0.0.0.0` or `::`.
    static let loopbackAddresses = ["127.0.0.1", "::1"]

    let addresses: [String]
    let limits: Limits
    let queue = DispatchQueue(label: "colimabar.domains")
    private let log = Logger(category: "domains")
    private let table = OSAllocatedUnfairLock(initialState: DomainRoutes.empty)
    private let failureHandler = OSAllocatedUnfairLock<(@Sendable () -> Void)?>(initialState: nil)

    private let httpsFailureHandler = OSAllocatedUnfairLock<(@Sendable () -> Void)?>(initialState: nil)

    /// One listener pair (127.0.0.1 and ::1) with its own state. `queue` guards it.
    private final class Front: @unchecked Sendable {
        let isTLS: Bool
        var listeners: [NWListener] = []
        var generation = 0
        var boundPort: UInt16?
        /// The latest close of listeners. A new start waits for it, even after a stop.
        var latestDrain: ListenerDrain?
        /// The bind attempt that runs now. The next start or stop aborts it.
        var currentAttempt: Attempt?
        init(isTLS: Bool) { self.isTLS = isTLS }
    }

    // Guarded by `queue`.
    private let httpFront = Front(isTLS: false)
    private let httpsFront = Front(isTLS: true)
    private var sessions: [ObjectIdentifier: DomainSession] = [:]
    /// Connections that get the busy page. `stop()` cancels them.
    private var rejects: [ObjectIdentifier: (connection: NWConnection, isTLS: Bool)] = [:]

    /// The proxy serves the local Mac only: any other address stops the app.
    convenience init(addresses: [String] = DomainProxy.loopbackAddresses, limits: Limits = .init()) {
        precondition(
            Set(addresses).isSubset(of: Self.loopbackAddresses), "The domain proxy binds loopback addresses only")
        self.init(unchecked: addresses, limits: limits)
    }

    /// For a test that needs an address which the interface does not have.
    init(unchecked addresses: [String], limits: Limits = .init()) {
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

    /// Called when the HTTPS listener fails after it was ready.
    var onHTTPSListenerFailure: (@Sendable () -> Void)? {
        get { httpsFailureHandler.withLock { $0 } }
        set { httpsFailureHandler.withLock { $0 = newValue } }
    }

    /// The port that the proxy listens on, or nil.
    var port: UInt16? { queue.sync { httpFront.boundPort } }

    /// The port of the HTTPS listener, or nil.
    var httpsPort: UInt16? { queue.sync { httpsFront.boundPort } }

    var sessionCount: Int { queue.sync { sessions.count } }

    /// The port, for code that already runs on `queue`.
    var portOnQueue: UInt16? { httpFront.boundPort }

    /// The HTTPS port, for code that already runs on `queue`.
    var httpsPortOnQueue: UInt16? { httpsFront.boundPort }

    /// Binds the first candidate that every address accepts. Returns it, or
    /// nil. A call replaces the listeners of an earlier start. `stop()`
    /// while a start runs makes the start return nil with nothing bound.
    func start(candidates: [UInt16]) async -> UInt16? {
        await start(httpFront, candidates: candidates, tls: nil)
    }

    func startHTTPS(candidates: [UInt16], tls: @escaping @Sendable () -> NWProtocolTLS.Options) async -> UInt16? {
        await start(httpsFront, candidates: candidates, tls: tls)
    }

    private func start(
        _ front: Front, candidates: [UInt16], tls: (@Sendable () -> NWProtocolTLS.Options)?
    ) async -> UInt16? {
        // A test process never binds a port that the user's own tools may serve.
        let candidates =
            TestProcess.isRunning ? candidates.filter { ![80, 443, 8080, 8443].contains($0) } : candidates
        let (gen, closing) = queue.sync { () -> (Int, ListenerDrain) in
            front.generation += 1
            return (front.generation, tearDownListeners(front))
        }
        // `cancel()` is asynchronous. A probe before the old socket is closed would find our own port busy.
        await waitForClose(closing)
        for candidate in candidates {
            guard queue.sync(execute: { front.generation == gen }) else { return nil }
            if await isBusy(candidate) {
                log.notice("port \(candidate, privacy: .public) is busy")
                continue
            }
            let bound = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
                queue.async {
                    self.bind(candidate, front: front, generation: gen, tls: tls) { cont.resume(returning: $0) }
                }
            }
            if bound {
                log.notice("listening on port \(candidate, privacy: .public)")
                return candidate
            }
        }
        return nil
    }

    func isFree(port: UInt16) async -> Bool { await !isBusy(port) }

    private func isBusy(_ port: UInt16) async -> Bool {
        for address in addresses
        where await PortProbe.listens(port: Int(port), ipv6: address.contains(":"), timeout: limits.probeTimeout) {
            return true
        }
        return false
    }

    /// The old listeners that are closing. `queue` guards it.
    private final class ListenerDrain: @unchecked Sendable {
        var remaining: Int
        private var waiters: [@Sendable () -> Void] = []
        init(_ count: Int) { remaining = count }

        func listenerClosed() {
            remaining -= 1
            guard remaining == 0 else { return }
            let run = waiters
            waiters = []
            for w in run { w() }
        }

        /// Runs `body` when nothing remains: at once, or later.
        func notify(_ body: @escaping @Sendable () -> Void) {
            if remaining <= 0 { body() } else { waiters.append(body) }
        }
    }

    /// Resumes a continuation once, from `queue`.
    private final class Once: @unchecked Sendable {
        private var resume: (() -> Void)?
        init(_ resume: @escaping () -> Void) { self.resume = resume }
        func fire() {
            guard let resume else { return }
            self.resume = nil
            resume()
        }
    }

    /// Waits until every listener of `drain` is `.cancelled`, at most `closeTimeout`.
    private func waitForClose(_ drain: ListenerDrain) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            queue.async {
                let once = Once { cont.resume() }
                drain.notify { once.fire() }
                self.queue.asyncAfter(deadline: .now() + self.limits.closeTimeout) { once.fire() }
            }
        }
    }

    /// Cancels the listeners and every session.
    func stop() {
        queue.sync { stopOnQueue() }
    }

    /// Cancels the HTTPS listener and the sessions that use it.
    func stopHTTPS() {
        queue.sync { stopFront(httpsFront) }
    }

    /// For tests: acts as if a ready listener failed.
    func simulateListenerFailure() { queue.sync { listenerFailed(httpFront) } }

    /// For tests: acts as if the ready HTTPS listener failed.
    func simulateHTTPSListenerFailure() { queue.sync { listenerFailed(httpsFront) } }

    /// The connections that wait to get the busy page.
    var rejectCount: Int { queue.sync { rejects.count } }

    /// Called by a session, on `queue`, when it ends.
    func sessionEnded(_ session: DomainSession) {
        sessions[ObjectIdentifier(session)] = nil
    }

    // MARK: - Queue only

    private func stopOnQueue() {
        stopFront(httpFront)
        stopFront(httpsFront)
    }

    /// Cancels the listeners of `front` and the sessions and busy pages that use them.
    private func stopFront(_ front: Front) {
        front.generation += 1
        tearDownListeners(front)
        let open = sessions.filter { $0.value.isTLS == front.isTLS }
        for (key, session) in open {
            sessions[key] = nil
            session.cancel()
        }
        let pending = rejects.filter { $0.value.isTLS == front.isTLS }
        for (key, reject) in pending {
            rejects[key] = nil
            reject.connection.cancel()
        }
    }

    /// Cancels the bound listeners and the ones of a bind that runs now. The
    /// drain also waits for an earlier drain, so a start after a stop waits too.
    @discardableResult
    private func tearDownListeners(_ front: Front) -> ListenerDrain {
        var closing = front.listeners
        if let attempt = front.currentAttempt {
            closing += attempt.listeners.map(\.listener)
            attempt.abort?()
        }
        let drain = ListenerDrain(closing.count)
        if let previous = front.latestDrain, previous.remaining > 0 {
            drain.remaining += 1
            previous.notify { [drain] in drain.listenerClosed() }
        }
        for l in closing {
            l.stateUpdateHandler = { [drain] state in
                if case .cancelled = state { drain.listenerClosed() }
            }
            l.cancel()
        }
        front.listeners = []
        front.boundPort = nil
        front.latestDrain = drain
        return drain
    }

    /// What one bind attempt knows. `queue` guards it.
    private final class Attempt: @unchecked Sendable {
        var listeners: [(address: String, listener: NWListener)] = []
        var states: [String: NWListener.State] = [:]
        var unavailable: Set<String> = []
        var done = false
        var timeout: DispatchWorkItem?
        /// Ends the attempt with no success and cancels its listeners.
        var abort: (@Sendable () -> Void)?
    }

    private func bind(
        _ port: UInt16, front: Front, generation gen: Int, tls: (@Sendable () -> NWProtocolTLS.Options)?,
        completion: @escaping @Sendable (Bool) -> Void
    ) {
        guard front.generation == gen, let endpointPort = NWEndpoint.Port(rawValue: port) else {
            return completion(false)
        }
        let attempt = Attempt()
        front.currentAttempt = attempt

        @Sendable func finish(_ success: Bool) {
            guard !attempt.done else { return }
            attempt.done = true
            attempt.timeout?.cancel()
            attempt.abort = nil
            if front.currentAttempt === attempt { front.currentAttempt = nil }
            if success, front.generation == gen {
                var held: [NWListener] = []
                for (address, listener) in attempt.listeners {
                    if attempt.unavailable.contains(address) { listener.cancel() } else { held.append(listener) }
                }
                front.listeners = held
                front.boundPort = port
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

        attempt.abort = { finish(false) }
        for address in addresses {
            attempt.states[address] = .setup
            let tcp = NWProtocolTCP.Options()
            tcp.noDelay = true
            let parameters = NWParameters(tls: tls?(), tcp: tcp)
            parameters.allowLocalEndpointReuse = true
            (parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options)?.version =
                address.contains(":") ? .v6 : .v4
            parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(address), port: endpointPort)
            guard let listener = try? NWListener(using: parameters) else {
                for (_, l) in attempt.listeners { l.cancel() }
                attempt.done = true
                attempt.abort = nil
                if front.currentAttempt === attempt { front.currentAttempt = nil }
                return completion(false)
            }
            attempt.listeners.append((address, listener))
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                guard let self, let listener else { return }
                if attempt.done {
                    if case .failed = state, front.listeners.contains(where: { $0 === listener }) {
                        listenerFailed(front)
                    }
                    return
                }
                attempt.states[address] = state
                evaluate()
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection, front: front, generation: gen)
            }
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

    private func listenerFailed(_ front: Front) {
        log.error("a listener failed")
        stopFront(front)
        if front.isTLS { onHTTPSListenerFailure?() } else { onListenerFailure?() }
    }

    private func accept(_ connection: NWConnection, front: Front, generation gen: Int) {
        // A listener of an old start, or one that stop() cancelled, may still deliver a queued connection.
        guard gen == front.generation, front.boundPort != nil else { return connection.cancel() }
        guard sessions.count < limits.maxSessions else {
            guard rejects.count < limits.maxSessions else { return connection.cancel() }
            let key = ObjectIdentifier(connection)
            rejects[key] = (connection, front.isTLS)
            connection.start(queue: queue)
            FinalPage(connection: connection, queue: queue, grace: limits.pageGrace) { [weak self] in
                self?.rejects[key] = nil
                connection.cancel()
            }.run(DomainPage.response(.busy, headOnly: false))
            return
        }
        let session = DomainSession(
            client: connection, proxy: self, queue: queue, limits: limits, isTLS: front.isTLS)
        sessions[ObjectIdentifier(session)] = session
        session.start()
    }
}

/// Sends a last page and closes the write side. It then reads and drops what
/// the client still sends, so that the close does not reset the connection
/// and the client can read the page. It calls `done` once, when the client
/// closes or after `grace` seconds. It lives on `queue` only.
final class FinalPage: @unchecked Sendable {
    private let connection: NWConnection
    private let queue: DispatchQueue
    private let grace: TimeInterval
    private var done: (() -> Void)?
    private var timer: DispatchSourceTimer?

    init(connection: NWConnection, queue: DispatchQueue, grace: TimeInterval, done: @escaping () -> Void) {
        self.connection = connection
        self.queue = queue
        self.grace = grace
        self.done = done
    }

    func run(_ page: Data) {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + grace)
        timer.setEventHandler { [self] in finish() }
        timer.resume()
        self.timer = timer
        connection.send(
            content: page, contentContext: .finalMessage, isComplete: true,
            completion: .contentProcessed { [self] error in
                if error != nil { finish() } else { drain() }
            })
    }

    private func drain() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [self] _, _, complete, error in
            if complete || error != nil { finish() } else { drain() }
        }
    }

    private func finish() {
        timer?.cancel()
        timer = nil
        guard let done else { return }
        self.done = nil
        done()
    }
}
