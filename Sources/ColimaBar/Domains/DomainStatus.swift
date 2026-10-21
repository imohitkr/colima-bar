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

    var phase: Phase = .off
    var httpPort: UInt16?
    /// The text for `.failed`.
    var problem: String?

    /// True when the proxy listens on a port other than 80.
    var usesFallback: Bool { httpPort.map { $0 != DomainPorts.http[0] } ?? false }

    /// The caption under the switch. nil for `.off`.
    func caption(routeCount: Int) -> String? {
        switch phase {
        case .off: return nil
        case .debugRun: return Help.domainsDebug
        case .starting: return "Starting the proxy…"
        case .failed: return "The proxy could not start. \(problem ?? "")"
        case .running:
            if usesFallback { return "Port 80 is busy, so the proxy listens on port \(httpPort ?? 0)." }
            let names = routeCount == 1 ? "1 container has a name." : "\(routeCount) containers have a name."
            return "The proxy listens on port \(httpPort ?? 80). \(names)"
        }
    }
}
