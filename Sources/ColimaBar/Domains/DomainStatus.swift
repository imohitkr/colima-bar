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
            /// The listener runs but macOS does not trust the certificate authority.
            case untrusted
            case failed
            /// ColimaBar removes the certificate authority.
            case removing
        }

        var phase: Phase = .off
        var port: UInt16?
        /// The text for `.failed`, or a note after a cancel or a removal.
        var problem: String?

        /// True when the HTTPS listener has a port that links can use.
        var listening: Bool { phase == .running || phase == .untrusted }

        /// True when the HTTPS listener uses a port other than 443.
        var usesFallback: Bool { port.map { $0 != DomainPorts.https[0] } ?? false }

        /// The caption under the HTTPS switch. nil when there is nothing to say.
        var caption: String? {
            switch phase {
            case .off: return problem
            case .settingUp: return "Setting up HTTPS…"
            case .removing: return "Removing the certificate authority…"
            case .failed: return "HTTPS could not start. \(problem ?? "")".trimmingCharacters(in: .whitespaces)
            case .untrusted: return "macOS does not trust the certificate authority. Browsers show a warning."
            case .running:
                return usesFallback
                    ? "Port 443 is busy, so HTTPS listens on port \(port ?? 0)."
                    : "HTTPS listens on port \(port ?? 443)."
            }
        }
    }

    var phase: Phase = .off
    var httpPort: UInt16?
    /// The text for `.failed`.
    var problem: String?
    var https = HTTPS()

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
