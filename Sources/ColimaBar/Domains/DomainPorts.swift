import Foundation

/// The ports of container domains.
enum DomainPorts {
    /// The ports of the proxy on this Mac, in the order that it tries them.
    static let http: [UInt16] = [80, 8080]
    /// Container ports that a route tries after the label, in this order.
    static let preferred: [Int] = [80, 8080, 3000, 8000, 5000, 5173, 4200, 8888, 443, 8443]
    /// Container ports that speak TLS (the `PortLink` rule). The proxy
    /// connects to them with TLS and accepts any certificate.
    static let tlsContainerPorts: Set<Int> = [443, 8443]

    /// `ports` without the ones in `published`, in the same order.
    static func candidates(_ ports: [UInt16], published: Set<Int>) -> [UInt16] {
        ports.filter { !published.contains(Int($0)) }
    }
}
