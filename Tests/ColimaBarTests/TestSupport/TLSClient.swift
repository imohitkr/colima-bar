import Foundation
import Network
import Security

/// A TLS client on 127.0.0.1 for the HTTPS listener. It sets the SNI value,
/// and it checks the chain of the server with `anchor` as the only anchor and
/// the SNI value as the name. Without an anchor it accepts any certificate
/// and only notes the name of the leaf. It never uses the system trust.
enum TLSClient {
    struct Result: Sendable {
        var text = ""
        var alpn: String?
        /// The common name of the leaf that the server sent.
        var leafName: String?
        /// True when the connection reached `.ready`.
        var connected = false
    }

    /// Sends `send` after the handshake and reads until `until` appears, the
    /// server closes, or `timeout` seconds pass. The 30 s is a liveness limit: a run
    /// returns as soon as the reply is in, and a stalled CI runner can freeze a test
    /// process for ~18 s.
    static func exchange(
        port: Int, sni: String?, anchor: SecCertificate?, alpns: [String] = ["http/1.1"], send: String,
        until: String, timeout: TimeInterval = 30
    ) async -> Result {
        guard let endpointPort = NWEndpoint.Port(rawValue: UInt16(port)) else { return Result() }
        let queue = DispatchQueue(label: "test.tls-client")
        let state = State()
        let options = NWProtocolTLS.Options()
        let security = options.securityProtocolOptions
        if let sni { sec_protocol_options_set_tls_server_name(security, sni) }
        for alpn in alpns { sec_protocol_options_add_tls_application_protocol(security, alpn) }
        sec_protocol_options_set_verify_block(
            security,
            { _, trustRef, complete in
                let trust = sec_trust_copy_ref(trustRef).takeRetainedValue()
                if let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let leaf = chain.first {
                    state.update { $0.leafName = SecCertificateCopySubjectSummary(leaf) as String? }
                }
                guard let anchor else { return complete(true) }
                SecTrustSetPolicies(trust, SecPolicyCreateSSL(true, sni.map { $0 as CFString }))
                SecTrustSetAnchorCertificates(trust, [anchor] as CFArray)
                SecTrustSetAnchorCertificatesOnly(trust, true)
                complete(SecTrustEvaluateWithError(trust, nil))
            }, queue)
        let connection = NWConnection(
            host: "127.0.0.1", port: endpointPort, using: NWParameters(tls: options, tcp: NWProtocolTCP.Options()))
        return await withCheckedContinuation { (continuation: CheckedContinuation<Result, Never>) in
            let finish: @Sendable () -> Void = {
                connection.cancel()
                if let result = state.finish() { continuation.resume(returning: result) }
            }
            queue.asyncAfter(deadline: .now() + timeout, execute: finish)
            @Sendable func read() {
                connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, complete, error in
                    if let data { state.update { $0.text += String(decoding: data, as: UTF8.self) } }
                    if complete || error != nil || state.snapshot().text.contains(until) {
                        finish()
                    } else {
                        read()
                    }
                }
            }
            connection.stateUpdateHandler = { newState in
                switch newState {
                case .ready:
                    state.update {
                        $0.connected = true
                        if let meta = connection.metadata(definition: NWProtocolTLS.definition)
                            as? NWProtocolTLS.Metadata
                        {
                            $0.alpn = sec_protocol_metadata_get_negotiated_protocol(meta.securityProtocolMetadata)
                                .map { String(cString: $0) }
                        }
                    }
                    connection.send(content: Data(send.utf8), completion: .contentProcessed { _ in })
                    read()
                case .failed, .cancelled:
                    finish()
                case .waiting:
                    // A refused connection or a failed handshake waits and does not fail.
                    finish()
                default:
                    break
                }
            }
            connection.start(queue: queue)
        }
    }

    private final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var value = Result()
        private var done = false
        func update(_ change: (inout Result) -> Void) { lock.withLock { change(&value) } }
        func snapshot() -> Result { lock.withLock { value } }
        /// The result on the first call, nil afterwards.
        func finish() -> Result? {
            lock.withLock {
                guard !done else { return nil }
                done = true
                return value
            }
        }
    }
}
