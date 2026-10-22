import Foundation

/// What the System tab shows about the domain proxy.
struct DomainStatus: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        case off
        case debugRun
        case starting
        case running
        case failed
    }

    /// What the System tab shows about HTTPS.
    struct HTTPS: Equatable, Sendable {
        enum Phase: Equatable, Sendable {
            case off
            case settingUp
            /// The listener runs and macOS trusts the certificate authority.
            case running
            /// macOS does not trust the certificate authority, or the authority does not cover the names. The listener runs only in the first case.
            case untrusted
            case failed
            /// ColimaBar removes the certificate authority.
            case removing
        }

        var phase: Phase = .off
        var port: UInt16?
        /// The text for `.failed`, a note after a cancel or a removal, or why `.untrusted` has no listener.
        var problem: String?
        /// A removal of the CA did not end. A button offers the clean-up (`.off` only).
        var offersCleanUp = false
        /// The CA covers every name but permits a name that is not in use any more. A button offers a replacement.
        var widerCA = false

        /// True when the HTTPS listener has a port that links can use.
        var listening: Bool { (phase == .running || phase == .untrusted) && port != nil }

        /// True when the HTTPS listener uses a port other than 443.
        var usesFallback: Bool { port.map { $0 != DomainPorts.https[0] } ?? false }

        /// The line under the caption when `widerCA` is set.
        static let widerCAText =
            "The certificate authority still permits a name that ColimaBar does not use. Replace it to remove that name."

        /// The caption under the HTTPS switch. nil when there is nothing to say.
        var caption: String? {
            switch phase {
            case .off: return problem
            case .settingUp: return "Setting up HTTPS…"
            case .removing: return "Removing the certificate authority…"
            case .failed: return problem ?? "HTTPS could not start."
            case .untrusted:
                return problem ?? "macOS does not trust the certificate authority. Browsers show a warning."
            case .running:
                return usesFallback
                    ? "Port 443 is busy, so HTTPS listens on port \(port ?? 0)."
                    : "HTTPS listens on port \(port ?? 443)."
            }
        }
    }

    /// What the System tab shows about the DNS server of the custom suffix.
    struct DNS: Equatable, Sendable {
        enum Phase: Equatable, Sendable {
            case off
            case applying
            case running
            /// The server runs, but macOS does not use the resolver file yet.
            case notUsedYet
            case failed
        }

        var phase: Phase = .off
        var port: UInt16?
        /// The text for `.failed` and `.notUsedYet`.
        var problem: String?
        /// A note after a cancel or a refusal. The state did not change.
        var note: String?

        /// The caption under the suffix field. `example` is a name that works now.
        func caption(suffix: String?, example: String?) -> String? {
            if let note { return note }
            switch phase {
            case .off: return nil
            case .applying: return "Writing the resolver file…"
            case .failed: return problem ?? "The DNS server could not start."
            case .notUsedYet:
                return problem
                    ?? "macOS does not use /etc/resolver/\(suffix ?? "") yet. Wait a moment, or turn the suffix off and on."
            case .running:
                if let example { return "\(example) works on this Mac." }
                return "Names under \(suffix ?? DomainSuffix.defaultValue) work on this Mac."
            }
        }
    }

    var phase: Phase = .off
    var httpPort: UInt16?
    /// The text for `.failed`.
    var problem: String?
    var https = HTTPS()
    var dns = DNS()

    /// True when the proxy listens on a port other than 80.
    var usesFallback: Bool { httpPort.map { $0 != DomainPorts.http[0] } ?? false }

    /// The caption under the switch. nil for `.off`.
    func caption(routeCount: Int) -> String? {
        switch phase {
        case .off: return nil
        case .debugRun: return Help.domainsDebug
        case .starting: return "Starting the proxy…"
        case .failed: return problem ?? "The proxy could not start."
        case .running:
            if usesFallback { return "Port 80 is busy, so the proxy listens on port \(httpPort ?? 0)." }
            let names = routeCount == 1 ? "1 container has a name." : "\(routeCount) containers have a name."
            return "The proxy listens on port \(httpPort ?? 80). \(names)"
        }
    }
}
