import Foundation
import Network
import Security

/// The TLS side of the HTTPS listener: the options with the challenge block
/// that picks a certificate by SNI, and the self-test.
final class DomainTLSServer: @unchecked Sendable {
    enum Mode: Sendable {
        /// One leaf for each name that a client asks for.
        case perSNI
        /// One leaf for all route names. It is the fallback if the challenge block does not work.
        case multiSAN
    }

    let cache: LeafCache
    let mode: Mode
    /// The names of the one certificate in `multiSAN` mode.
    let names: [String]

    init(cache: LeafCache, mode: Mode, names: [String] = []) {
        self.cache = cache
        self.mode = mode
        self.names = names
    }

    /// The TLS options of the HTTPS listener: TLS 1.2 or later, ALPN
    /// `http/1.1` only (so a browser never sends HTTP/2 frames to the head
    /// parser), and the certificate. `mintQueue` is a serial queue of its
    /// own, so minting never blocks the queue of the proxy.
    func options(mintQueue: DispatchQueue) -> NWProtocolTLS.Options {
        let options = NWProtocolTLS.Options()
        let security = options.securityProtocolOptions
        switch mode {
        case .perSNI:
            let cache = cache
            sec_protocol_options_set_challenge_block(
                security,
                { metadata, complete in
                    let sni = sec_protocol_metadata_get_server_name(metadata).map { String(cString: $0) }
                    complete(cache.identity(forSNI: sni))
                }, mintQueue)
        case .multiSAN:
            if let identity = cache.multiSANIdentity(names: names) {
                sec_protocol_options_set_local_identity(security, identity)
            }
        }
        sec_protocol_options_set_min_tls_protocol_version(security, .TLSv12)
        sec_protocol_options_add_tls_application_protocol(security, "http/1.1")
        return options
    }

    /// The host name of the self-test under `suffix`.
    static func selfTestHost(suffix: String = DomainName.localhost) -> String {
        "\(DomainName.selfTestLabel).\(suffix)"
    }

    /// The self-test for one name under each of `suffixes`. True when all pass.
    static func selfTest(
        port: UInt16, ca: LocalCA, suffixes: [String] = [DomainName.localhost], timeout: TimeInterval = 5
    ) async -> Bool {
        for suffix in suffixes
        where await !selfTest(port: port, ca: ca, host: selfTestHost(suffix: suffix), timeout: timeout) {
            return false
        }
        return true
    }

    /// Connects to 127.0.0.1:`port` with `host` as the SNI value and the CA
    /// as the only anchor, and sends a HEAD. True when the chain and the name
    /// pass and the proxy answers (404, or 503 if the VM is stopped).
    static func selfTest(port: UInt16, ca: LocalCA, host selfTestHost: String, timeout: TimeInterval) async -> Bool {
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else { return false }
        let queue = DispatchQueue(label: "colimabar.domains.selftest")
        let options = NWProtocolTLS.Options()
        let security = options.securityProtocolOptions
        sec_protocol_options_set_tls_server_name(security, selfTestHost)
        sec_protocol_options_add_tls_application_protocol(security, "http/1.1")
        let certificate = ca.certificate
        sec_protocol_options_set_verify_block(
            security,
            { _, trustRef, complete in
                let trust = sec_trust_copy_ref(trustRef).takeRetainedValue()
                SecTrustSetPolicies(trust, SecPolicyCreateSSL(true, selfTestHost as CFString))
                SecTrustSetAnchorCertificates(trust, [certificate] as CFArray)
                SecTrustSetAnchorCertificatesOnly(trust, true)
                complete(SecTrustEvaluateWithError(trust, nil))
            }, queue)
        let connection = NWConnection(
            host: "127.0.0.1", port: endpointPort, using: NWParameters(tls: options, tcp: NWProtocolTCP.Options()))
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let done = Once(continuation)
            queue.asyncAfter(deadline: .now() + timeout) {
                connection.cancel()
                done.finish(false)
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    let request = "HEAD / HTTP/1.1\r\nHost: \(selfTestHost)\r\nConnection: close\r\n\r\n"
                    connection.send(content: Data(request.utf8), completion: .contentProcessed { _ in })
                    connection.receive(minimumIncompleteLength: 1, maximumLength: 1024) { data, _, _, _ in
                        let text = data.map { String(decoding: $0, as: UTF8.self) } ?? ""
                        connection.cancel()
                        done.finish(text.hasPrefix("HTTP/1.1 404") || text.hasPrefix("HTTP/1.1 503"))
                    }
                case .failed, .waiting, .cancelled:
                    connection.cancel()
                    done.finish(false)
                default:
                    break
                }
            }
            connection.start(queue: queue)
        }
    }

    /// Resumes a continuation once.
    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Bool, Never>?
        init(_ continuation: CheckedContinuation<Bool, Never>) { self.continuation = continuation }
        func finish(_ value: Bool) {
            let c = lock.withLock { () -> CheckedContinuation<Bool, Never>? in
                defer { continuation = nil }
                return continuation
            }
            c?.resume(returning: value)
        }
    }
}
