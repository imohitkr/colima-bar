import Darwin
import Foundation
import Network
import os

/// What the model needs from the DNS responder. A test gives it a fake.
protocol DNSServing: AnyObject, Sendable {
    var zone: String { get set }
    var port: UInt16? { get }
    var onFailure: (@Sendable () -> Void)? { get set }
    func start(port: UInt16) async -> Bool
    func stop()
}

/// A responder that binds nothing. A model in a test process uses it when the
/// test gives no other responder.
final class InertDNSResponder: DNSServing, @unchecked Sendable {
    var zone = ""
    var port: UInt16? { nil }
    var onFailure: (@Sendable () -> Void)?
    func start(port: UInt16) async -> Bool { false }
    func stop() {}
}

/// A small DNS server for the custom suffix. It binds `127.0.0.1` over UDP
/// (the resolver file names that address and a high port) and answers only
/// inside `zone` (`DNSMessage`). It never binds another address.
///
/// `queue` runs every Network.framework handler and guards the listener, the
/// flows and the generation. `zone` has its own lock. `@unchecked Sendable`
/// for that reason.
final class DNSResponder: DNSServing, @unchecked Sendable {
    let address: String
    let maxFlows: Int
    let readyTimeout: TimeInterval
    let idleTimeout: TimeInterval
    /// A flow that sends more messages than this closes.
    let maxMessagesPerFlow = 64
    private let queue = DispatchQueue(label: "colimabar.dns")
    private let zoneLock = OSAllocatedUnfairLock(initialState: "")
    private let failureLock = OSAllocatedUnfairLock<(@Sendable () -> Void)?>(initialState: nil)
    private let log = Logger(category: "domains")

    // Guarded by `queue`.
    private var listener: NWListener?
    private var generation = 0
    private var boundPort: UInt16?
    private var flows: [ObjectIdentifier: Flow] = [:]

    /// Touched on `queue` only.
    private final class Flow: @unchecked Sendable {
        let connection: NWConnection
        var epoch = 0
        var handled = 0
        init(_ connection: NWConnection) { self.connection = connection }
    }

    /// The only address that production binds.
    static let loopback = "127.0.0.1"

    convenience init(maxFlows: Int = 256) {
        self.init(unchecked: Self.loopback, maxFlows: maxFlows)
    }

    /// For a test that needs other limits.
    init(unchecked address: String, maxFlows: Int = 256, readyTimeout: TimeInterval = 2, idleTimeout: TimeInterval = 5)
    {
        precondition(address == Self.loopback, "The DNS responder binds 127.0.0.1 only")
        self.address = address
        self.maxFlows = maxFlows
        self.readyTimeout = readyTimeout
        self.idleTimeout = idleTimeout
    }

    var zone: String {
        get { zoneLock.withLock { $0 } }
        set { zoneLock.withLock { $0 = DomainSuffix.normalized(newValue) } }
    }

    var onFailure: (@Sendable () -> Void)? {
        get { failureLock.withLock { $0 } }
        set { failureLock.withLock { $0 = newValue } }
    }

    var port: UInt16? { queue.sync { boundPort } }

    /// The number of open flows.
    var flowCount: Int { queue.sync { flows.count } }

    /// Binds `127.0.0.1:port`, or a free port when `port` is 0 (a test uses
    /// that; read the port back from `port`). True when the listener is
    /// ready. A call replaces an earlier listener, and `stop()` during a start
    /// makes the start return false with nothing bound.
    func start(port: UInt16) async -> Bool {
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else { return false }
        let (gen, old) = queue.sync { () -> (Int, NWListener?) in
            generation += 1
            let old = listener
            tearDown()
            return (generation, old)
        }
        await waitForClose(old)
        return await withCheckedContinuation { cont in
            queue.async { self.openListener(endpointPort, generation: gen) { cont.resume(returning: $0) } }
        }
    }

    func stop() {
        queue.sync {
            generation += 1
            tearDown()
        }
    }

    // MARK: - Queue only

    private func tearDown() {
        listener?.cancel()
        listener = nil
        boundPort = nil
        for (_, flow) in flows { flow.connection.cancel() }
        flows = [:]
    }

    private func waitForClose(_ old: NWListener?) async {
        guard let old, old.state != .cancelled else { return }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            let once = OSAllocatedUnfairLock<CheckedContinuation<Void, Never>?>(initialState: cont)
            @Sendable func fire() {
                once.withLock { c in
                    c?.resume()
                    c = nil
                }
            }
            old.stateUpdateHandler = { if $0 == .cancelled { fire() } }
            queue.asyncAfter(deadline: .now() + 1) { fire() }
        }
    }

    private func openListener(
        _ port: NWEndpoint.Port, generation gen: Int, completion: @escaping @Sendable (Bool) -> Void
    ) {
        guard generation == gen else { return completion(false) }
        let parameters = NWParameters.udp
        parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(address), port: port)
        guard let made = try? NWListener(using: parameters) else { return completion(false) }
        let done = OSAllocatedUnfairLock(initialState: false)
        @Sendable func finish(_ ok: Bool) {
            let first = done.withLock { d -> Bool in
                defer { d = true }
                return !d
            }
            guard first else { return }
            if ok, generation == gen {
                listener = made
                boundPort = made.port?.rawValue ?? port.rawValue
            } else {
                made.cancel()
            }
            completion(ok && generation == gen)
        }
        made.newConnectionHandler = { [weak self] connection in self?.accept(connection, generation: gen) }
        made.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                finish(true)
            case .failed, .cancelled:
                if done.withLock({ $0 }) {
                    guard generation == gen, listener === made else { return }
                    log.error("the DNS listener stopped")
                    tearDown()
                    onFailure?()
                } else {
                    finish(false)
                }
            case .waiting:
                finish(false)
            default:
                break
            }
        }
        made.start(queue: queue)
        queue.asyncAfter(deadline: .now() + readyTimeout) { finish(false) }
    }

    /// One flow for each source endpoint. A client such as `getaddrinfo` sends
    /// the A and the AAAA query from one socket, so the flow keeps reading: it
    /// answers each message, and it closes after `idleTimeout` without a
    /// message or after `maxMessagesPerFlow` messages.
    private func accept(_ connection: NWConnection, generation gen: Int) {
        guard generation == gen, flows.count < maxFlows else { return connection.cancel() }
        let flow = Flow(connection)
        let id = ObjectIdentifier(connection)
        flows[id] = flow
        connection.stateUpdateHandler = { [weak self] state in
            if case .cancelled = state { self?.flows[id] = nil }
        }
        connection.start(queue: queue)
        arm(flow)
    }

    /// Waits for the next message of the flow and restarts its idle timer.
    private func arm(_ flow: Flow) {
        flow.epoch += 1
        let epoch = flow.epoch
        queue.asyncAfter(deadline: .now() + idleTimeout) { [weak flow] in
            if let flow, flow.epoch == epoch { flow.connection.cancel() }
        }
        flow.connection.receiveMessage { [weak self, weak flow] data, _, _, error in
            guard let self, let flow else { return }
            guard let data, error == nil else { return flow.connection.cancel() }
            flow.handled += 1
            // The last message of the flow gets its answer. The close follows the send.
            let last = flow.handled >= maxMessagesPerFlow
            if !data.isEmpty, let reply = DNSMessage.response(to: [UInt8](data), zone: zone) {
                if last {
                    flow.connection.send(
                        content: Data(reply),
                        completion: .contentProcessed { [weak flow] _ in flow?.connection.cancel() })
                    return
                }
                flow.connection.send(content: Data(reply), completion: .idempotent)
            }
            if last { return flow.connection.cancel() }
            arm(flow)
        }
    }

    // MARK: - Ports

    /// True when no socket of this Mac holds the UDP port on 127.0.0.1. It
    /// binds a plain socket for a moment and closes it.
    static func isFree(port: Int) -> Bool {
        guard (1...65535).contains(port) else { return false }
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(port).bigEndian
        addr.sin_addr.s_addr = inet_addr(loopback)
        return withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }
}
