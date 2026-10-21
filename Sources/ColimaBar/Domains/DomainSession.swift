import Foundation
import Network
import os

/// One client connection of the domain proxy. It reads the head of the first
/// request, finds the route, connects to the upstream and splices the bytes
/// both ways. It confines itself to the proxy queue.
final class DomainSession: @unchecked Sendable {
    private let client: NWConnection
    private let proxy: DomainProxy
    private let queue: DispatchQueue
    private let limits: DomainProxy.Limits
    private let log = Logger(category: "domains")

    private var head: [UInt8] = []
    private var upstream: NWConnection?
    private var headTimer: DispatchSourceTimer?
    private var routed = false
    private var finished = false
    private var clientHalfClosed = false
    /// The client sent its last byte with the head, so there is no more to read.
    private var clientReadEnded = false
    private var upstreamHalfClosed = false

    init(client: NWConnection, proxy: DomainProxy, queue: DispatchQueue, limits: DomainProxy.Limits) {
        self.client = client
        self.proxy = proxy
        self.queue = queue
        self.limits = limits
    }

    func start() {
        client.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.end()
            default: break
            }
        }
        client.start(queue: queue)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + limits.headTimeout)
        timer.setEventHandler { [weak self] in
            guard let self, !routed, !finished else { return }
            respond(.timeout, headOnly: false)
        }
        timer.resume()
        headTimer = timer
        readHead()
    }

    func cancel() { end() }

    /// The parameters of the upstream connection. A route to a TLS port
    /// (443, 8443) uses TLS and accepts any certificate: the proxy talks to a
    /// container on this Mac, and the browser sees no upstream certificate.
    static func upstreamParameters(
        tls: Bool, host: String, connectTimeout: Int = 5, queue: DispatchQueue = .global()
    ) -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.connectionTimeout = connectTimeout
        guard tls else { return NWParameters(tls: nil, tcp: tcp) }
        let options = NWProtocolTLS.Options()
        let security = options.securityProtocolOptions
        sec_protocol_options_set_verify_block(security, { _, _, done in done(true) }, queue)
        sec_protocol_options_set_tls_server_name(security, host)
        sec_protocol_options_add_tls_application_protocol(security, "http/1.1")
        return NWParameters(tls: options, tcp: tcp)
    }

    // MARK: - Head

    private func readHead() {
        client.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, complete, error in
            guard let self, !finished, !routed else { return }
            if let data, !data.isEmpty { head.append(contentsOf: data) }
            if complete { clientReadEnded = true }
            switch HTTPHead.parse(head) {
            case .success(let parsed):
                route(parsed)
            case .failure(.tooLarge):
                respond(.headTooLarge, headOnly: false)
            case .failure(.incomplete):
                if complete || error != nil { end() } else { readHead() }
            case .failure:
                respond(.badRequest, headOnly: false)
            }
        }
    }

    private func route(_ request: HTTPHead) {
        let table = proxy.routes
        switch table.resolve(host: request.host ?? "") {
        case .foreign:
            respond(.foreign, headOnly: request.isHead)
        case .unknown:
            let host = request.host.flatMap(DomainName.normalizedHost) ?? ""
            let port = proxy.portOnQueue.flatMap { $0 == 80 ? nil : ":\($0)" } ?? ""
            let suffix = table.suffixes.first ?? DomainName.localhost
            let known = table.routes.keys.sorted().map { DomainLink.host(relative: $0, suffix: suffix) + port }
            respond(.notFound(host: host, profile: table.profile, known: known), headOnly: request.isHead)
        case .vmStopped:
            respond(.vmStopped(profile: table.profile), headOnly: request.isHead)
        case .route(let route):
            connectUpstream(route, request: request)
        }
    }

    private func respond(_ kind: DomainPage.Kind, headOnly: Bool) {
        guard !finished else { return }
        headTimer?.cancel()
        headTimer = nil
        routed = true
        client.send(
            content: DomainPage.response(kind, headOnly: headOnly),
            completion: .contentProcessed { [weak self] _ in self?.end() })
    }

    // MARK: - Splice

    private func connectUpstream(_ route: DomainRoutes.Route, request: HTTPHead) {
        guard let port = NWEndpoint.Port(rawValue: UInt16(truncatingIfNeeded: route.hostPort)),
            (1...65535).contains(route.hostPort)
        else { return respond(.badRequest, headOnly: false) }
        let host = request.host.flatMap(DomainName.normalizedHost) ?? "localhost"
        let connection = NWConnection(
            host: "127.0.0.1", port: port,
            using: Self.upstreamParameters(
                tls: route.upstreamTLS, host: host, connectTimeout: limits.connectTimeout, queue: queue))
        upstream = connection
        routed = true
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection, !finished else { return }
            switch state {
            case .ready:
                spliceStarted(connection)
            case .failed, .waiting:
                // After the splice, a failed upstream is no reason to end the session
                // at once: its pending read still delivers the bytes that arrived
                // and then ends that direction (see `pump`).
                if spliced {
                    break
                } else {
                    log.notice("upstream port \(route.hostPort, privacy: .public) does not answer")
                    connection.cancel()
                    upstream = nil
                    routed = false
                    respond(
                        .upstreamDown(
                            host: host, container: route.containerName, containerPort: route.containerPort,
                            hostPort: route.hostPort),
                        headOnly: request.isHead)
                }
            case .cancelled:
                if spliced { end() }
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private var spliced = false

    private func spliceStarted(_ connection: NWConnection) {
        guard !spliced else { return }
        spliced = true
        headTimer?.cancel()
        headTimer = nil
        // The head and any early body bytes go first.
        connection.send(
            content: Data(head),
            completion: .contentProcessed { [weak self] error in
                guard let self, !finished else { return }
                if error != nil { return end() }
                head = []
                if clientReadEnded {
                    halfClose(connection, fromClient: true)
                } else {
                    pump(from: client, to: connection, fromClient: true)
                }
                pump(from: connection, to: client, fromClient: false)
            })
    }

    /// Copies one direction. It reads again only after the send is processed
    /// (backpressure). An end of stream, or an error, from one side half-closes
    /// the other. Bytes that arrive with the end still go out first.
    private func pump(from source: NWConnection, to target: NWConnection, fromClient: Bool) {
        source.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, complete, error in
            guard let self, !finished else { return }
            let last = complete || error != nil
            guard let data, !data.isEmpty else {
                if last {
                    halfClose(target, fromClient: fromClient)
                } else {
                    pump(from: source, to: target, fromClient: fromClient)
                }
                return
            }
            target.send(
                content: data,
                completion: .contentProcessed { [weak self] sendError in
                    guard let self, !finished else { return }
                    if sendError != nil { return end() }
                    if last {
                        halfClose(target, fromClient: fromClient)
                    } else {
                        pump(from: source, to: target, fromClient: fromClient)
                    }
                })
        }
    }

    private func halfClose(_ target: NWConnection, fromClient: Bool) {
        if fromClient { clientHalfClosed = true } else { upstreamHalfClosed = true }
        target.send(
            content: nil, contentContext: .finalMessage, isComplete: true,
            completion: .contentProcessed { [weak self] _ in
                guard let self, !finished else { return }
                if clientHalfClosed && upstreamHalfClosed { end() }
            })
    }

    private func end() {
        guard !finished else { return }
        finished = true
        headTimer?.cancel()
        headTimer = nil
        client.stateUpdateHandler = nil
        upstream?.stateUpdateHandler = nil
        client.cancel()
        upstream?.cancel()
        upstream = nil
        proxy.sessionEnded(self)
    }
}
