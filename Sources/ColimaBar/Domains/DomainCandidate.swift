import Foundation

/// A running container as the routing sees it. It holds only what the rules
/// need, as plain values, so `DomainRoutes.build` stays pure.
struct DomainCandidate: Equatable, Sendable {
    struct PortMap: Equatable, Sendable {
        let containerPort: Int
        let hostPort: Int
        /// The port is published on `::1` only, so the proxy dials `::1`.
        /// A port that is published on 127.0.0.1 too, or on a wildcard
        /// address, uses 127.0.0.1.
        var ipv6Only = false
    }

    /// A name from the label `dev.colimabar.domains`. `name` is full and lower case.
    struct Entry: Equatable, Sendable {
        let name: String
        let containerPort: Int?
    }

    enum Domains: Equatable, Sendable {
        /// The label is not set.
        case none
        /// The label says `off`: the container gets no name at all.
        case off
        case names([Entry])
    }

    static let portLabel = "dev.colimabar.port"
    static let orbStackPortLabel = "dev.orbstack.http-port"
    static let domainsLabel = "dev.colimabar.domains"
    static let maxEntries = 16

    private static let projectLabel = "com.docker.compose.project"
    private static let serviceLabel = "com.docker.compose.service"
    private static let numberLabel = "com.docker.compose.container-number"
    private static let hostIPs: Set<String> = ["0.0.0.0", "::", "127.0.0.1", "::1"]

    let id: String
    let name: String
    let created: Int64
    let project: String?
    let service: String?
    let number: Int?
    /// TCP ports that this Mac reaches, sorted by container port, then host port.
    let ports: [PortMap]
    /// `dev.colimabar.port`, else `dev.orbstack.http-port`.
    let labelPort: Int?
    /// The text of the port label when it is set but not a port.
    let labelPortInvalid: String?
    let domains: Domains
    /// The entries of `dev.colimabar.domains` that the parser dropped.
    let droppedEntries: [String]

    init(
        id: String, name: String, created: Int64 = 0, project: String? = nil, service: String? = nil,
        number: Int? = nil, ports: [PortMap] = [], labelPort: Int? = nil, labelPortInvalid: String? = nil,
        domains: Domains = .none, droppedEntries: [String] = []
    ) {
        self.id = id
        self.name = name
        self.created = created
        self.project = project
        self.service = service
        self.number = number
        self.ports = ports
        self.labelPort = labelPort
        self.labelPortInvalid = labelPortInvalid
        self.domains = domains
        self.droppedEntries = droppedEntries
    }

    /// nil when the container does not run, for `org.testcontainers=true`, and
    /// for a debug shell or a volume helper. The name is the first of `Names`
    /// without the leading `/`.
    init?(_ c: APIContainer) {
        let labels = c.Labels ?? [:]
        let raw = c.Names.first.map { String($0.drop { $0 == "/" }) }
        let name = raw.flatMap { $0.isEmpty ? nil : $0 } ?? String(c.Id.prefix(12))
        guard c.State == "running", labels["org.testcontainers"] != "true",
            !ColimaModel.isInternalContainer(name: name, attributes: labels)
        else { return nil }
        var v4 = Set<PortMap>()
        var v6 = Set<PortMap>()
        for p in Self.tcpPorts(c) {
            let key = PortMap(containerPort: p.inner, hostPort: p.host)
            // A port on "::" alone has no IPv4 listener: the proxy dials ::1.
            if p.ip == "::1" || p.ip == "::" { v6.insert(key) } else { v4.insert(key) }
        }
        id = c.Id
        self.name = name
        created = c.Created ?? 0
        let project = labels[Self.projectLabel].flatMap { ComposeProject.isValid(name: $0) ? $0 : nil }
        self.project = project
        service = project == nil ? nil : labels[Self.serviceLabel]
        number = project == nil ? nil : labels[Self.numberLabel].flatMap { Int($0) }
        ports = v4.union(v6)
            .map { PortMap(containerPort: $0.containerPort, hostPort: $0.hostPort, ipv6Only: !v4.contains($0)) }
            .sorted { ($0.containerPort, $0.hostPort) < ($1.containerPort, $1.hostPort) }
        // The first port label that is set decides. A bad value does not fall through to the next label.
        let portText = [labels[Self.portLabel], labels[Self.orbStackPortLabel]].lazy.compactMap { $0 }.first
        let portValue = portText.flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        if let portValue, (1...65535).contains(portValue) {
            labelPort = portValue
            labelPortInvalid = nil
        } else {
            labelPort = nil
            labelPortInvalid = portText.map { String($0.prefix(40)) }
        }
        let scanned = Self.scanDomains(labels[Self.domainsLabel])
        domains = scanned.domains
        droppedEntries = scanned.dropped
    }

    /// The TCP ports on 127.0.0.1, ::1 or a wildcard address that this Mac reaches.
    private static func tcpPorts(_ c: APIContainer) -> [(inner: Int, host: Int, ip: String)] {
        (c.Ports ?? []).compactMap { p in
            guard p.Type?.lowercased() == "tcp", let ip = p.IP, hostIPs.contains(ip),
                let host = p.PublicPort, let inner = p.PrivatePort,
                (1...65535).contains(host), (1...65535).contains(inner)
            else { return nil }
            return (inner, host, ip)
        }
    }

    /// The host ports that every running container publishes, internal and
    /// testcontainers ones too. A proxy port must not collide with any of them.
    static func publishedHostPorts(_ list: [APIContainer]) -> Set<Int> {
        Set(list.filter { $0.State == "running" }.flatMap { tcpPorts($0).map(\.host) })
    }

    /// "off" (any case, trimmed) gives `.off`. Else a comma list of `name` or
    /// `name@port`. An entry with `*`, an invalid name or a bad port drops.
    /// At most 16 entries.
    static func parseDomains(_ raw: String?) -> Domains { scanDomains(raw).domains }

    /// `parseDomains`, and the entries that it dropped (at most 16, each cut to 60 characters).
    static func scanDomains(_ raw: String?) -> (domains: Domains, dropped: [String]) {
        guard let raw else { return (.none, []) }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.lowercased() == "off" { return (.off, []) }
        var entries: [Entry] = []
        var dropped: [String] = []
        func drop(_ piece: String) {
            if dropped.count < maxEntries, !piece.isEmpty { dropped.append(String(piece.prefix(60))) }
        }
        for part in text.split(separator: ",") {
            guard entries.count < maxEntries else { break }
            let piece = part.trimmingCharacters(in: .whitespaces)
            guard !piece.contains("*") else {
                drop(piece)
                continue
            }
            var namePart = piece
            var port: Int?
            if let at = piece.lastIndex(of: "@") {
                namePart = String(piece[..<at])
                guard let p = Int(piece[piece.index(after: at)...].trimmingCharacters(in: .whitespaces)),
                    (1...65535).contains(p)
                else {
                    drop(piece)
                    continue
                }
                port = p
            }
            guard !namePart.contains(":"), let host = DomainName.normalizedHost(namePart) else {
                drop(piece)
                continue
            }
            entries.append(Entry(name: host, containerPort: port))
        }
        return (entries.isEmpty ? .none : .names(entries), dropped)
    }
}

extension DomainCandidate.PortMap: Hashable {}
