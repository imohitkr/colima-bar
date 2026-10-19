import Foundation

/// Builds the `localhost` link of a published port. The link comes from
/// integers only, never from text of a container.
enum PortLink {
    /// Ports of services that do not speak HTTP.
    static let nonWebPorts: Set<Int> = [
        22, 25, 53, 1433, 1521, 2181, 3306, 4222, 5432, 5672, 6379, 9092, 11211, 27017,
    ]
    private static let localHosts: Set<String> = ["", "0.0.0.0", "::", "127.0.0.1", "::1"]

    /// nil unless the port is a TCP port on this Mac that a browser can use.
    static func url(hostPort: Int, containerPort: Int, proto: String, hostIP: String) -> URL? {
        guard proto.lowercased() == "tcp", (1...65535).contains(hostPort), localHosts.contains(hostIP),
            !nonWebPorts.contains(hostPort), !nonWebPorts.contains(containerPort)
        else { return nil }
        let scheme = [443, 8443].contains(containerPort) ? "https" : "http"
        return URL(string: "\(scheme)://localhost:\(hostPort)")
    }
}
