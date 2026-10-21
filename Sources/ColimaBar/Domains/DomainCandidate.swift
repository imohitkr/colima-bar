import Foundation

/// A running container as the routing sees it. It holds only what the rules
/// need, as plain values, so `DomainRoutes.build` stays pure.
struct DomainCandidate: Equatable, Sendable {
    struct PortMap: Equatable, Sendable {
        let containerPort: Int
        let hostPort: Int
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
    let domains: Domains

    init(
        id: String, name: String, created: Int64 = 0, project: String? = nil, service: String? = nil,
        number: Int? = nil, ports: [PortMap] = [], labelPort: Int? = nil, domains: Domains = .none
    ) {
        self.id = id
        self.name = name
        self.created = created
        self.project = project
        self.service = service
        self.number = number
        self.ports = ports
        self.labelPort = labelPort
        self.domains = domains
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
        var seen = Set<PortMap>()
        for p in c.Ports ?? [] {
            guard p.Type?.lowercased() == "tcp", let ip = p.IP, Self.hostIPs.contains(ip),
                let host = p.PublicPort, let inner = p.PrivatePort,
                (1...65535).contains(host), (1...65535).contains(inner)
            else { continue }
            seen.insert(PortMap(containerPort: inner, hostPort: host))
        }
        id = c.Id
        self.name = name
        created = c.Created ?? 0
        let project = labels[Self.projectLabel].flatMap { ComposeProject.isValid(name: $0) ? $0 : nil }
        self.project = project
        service = project == nil ? nil : labels[Self.serviceLabel]
        number = project == nil ? nil : labels[Self.numberLabel].flatMap { Int($0) }
        ports = seen.sorted { ($0.containerPort, $0.hostPort) < ($1.containerPort, $1.hostPort) }
        labelPort = [labels[Self.portLabel], labels[Self.orbStackPortLabel]].lazy
            .compactMap { $0.flatMap { Int($0.trimmingCharacters(in: .whitespaces)) } }
            .first { (1...65535).contains($0) }
        domains = Self.parseDomains(labels[Self.domainsLabel])
    }

    /// "off" (any case, trimmed) gives `.off`. Else a comma list of `name` or
    /// `name@port`. An entry with `*`, an invalid name or a bad port drops.
    /// At most 16 entries.
    static func parseDomains(_ raw: String?) -> Domains {
        guard let raw else { return .none }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.lowercased() == "off" { return .off }
        var entries: [Entry] = []
        for part in text.split(separator: ",") {
            guard entries.count < maxEntries else { break }
            let piece = part.trimmingCharacters(in: .whitespaces)
            guard !piece.contains("*") else { continue }
            var namePart = piece
            var port: Int?
            if let at = piece.lastIndex(of: "@") {
                namePart = String(piece[..<at])
                guard let p = Int(piece[piece.index(after: at)...].trimmingCharacters(in: .whitespaces)),
                    (1...65535).contains(p)
                else { continue }
                port = p
            }
            guard !namePart.contains(":"), let host = DomainName.normalizedHost(namePart) else { continue }
            entries.append(Entry(name: host, containerPort: port))
        }
        return entries.isEmpty ? .none : .names(entries)
    }
}

extension DomainCandidate.PortMap: Hashable {}
