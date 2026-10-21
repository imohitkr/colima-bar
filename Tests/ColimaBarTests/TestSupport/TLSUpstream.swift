import Foundation
import Network
import Security

/// A TLS HTTP server on 127.0.0.1 with a self-signed certificate. It stands
/// in for a container that publishes a TLS port (443, 8443). It answers each
/// request head with 200 and `tls-upstream sni=<server name> alpn=<protocol>`.
/// `@unchecked Sendable`: the queue guards the listener, and the fields never change.
final class TLSUpstream: @unchecked Sendable {
    let port: Int
    private let listener: NWListener
    private let queue = DispatchQueue(label: "test.tls-upstream")

    /// nil when the identity or the listener fails.
    static func start() async -> TLSUpstream? {
        guard let identity = SelfSignedIdentity.make(), let secIdentity = sec_identity_create(identity) else {
            return nil
        }
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_local_identity(tls.securityProtocolOptions, secIdentity)
        sec_protocol_options_add_tls_application_protocol(tls.securityProtocolOptions, "http/1.1")
        let parameters = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        guard let listener = try? NWListener(using: parameters) else { return nil }
        let queue = DispatchQueue(label: "test.tls-upstream")
        let ready = Ready()
        listener.stateUpdateHandler = { state in if case .ready = state { ready.set() } }
        listener.newConnectionHandler = { connection in Self.serve(connection, queue: queue) }
        listener.start(queue: queue)
        guard await waitUntil({ ready.value && listener.port != nil }), let port = listener.port else {
            listener.cancel()
            return nil
        }
        return TLSUpstream(listener: listener, port: Int(port.rawValue))
    }

    private init(listener: NWListener, port: Int) {
        self.listener = listener
        self.port = port
    }

    func stop() { listener.cancel() }

    deinit { listener.cancel() }

    private final class Ready: @unchecked Sendable {
        private let lock = NSLock()
        private var flag = false
        var value: Bool { lock.withLock { flag } }
        func set() { lock.withLock { flag = true } }
    }

    private static func serve(_ connection: NWConnection, queue: DispatchQueue) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, _, _ in
            guard data != nil,
                let metadata = connection.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata
            else { return connection.cancel() }
            let meta = metadata.securityProtocolMetadata
            let sni = sec_protocol_metadata_get_server_name(meta).map { String(cString: $0) } ?? "none"
            let alpn = sec_protocol_metadata_get_negotiated_protocol(meta).map { String(cString: $0) } ?? "none"
            let body = "tls-upstream sni=\(sni) alpn=\(alpn)"
            let reply = "HTTP/1.1 200 OK\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
            connection.send(
                content: Data(reply.utf8), contentContext: .finalMessage, isComplete: true,
                completion: .contentProcessed { _ in connection.cancel() })
        }
    }
}
