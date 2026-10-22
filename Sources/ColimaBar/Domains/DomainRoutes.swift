import Foundation

/// The table of container names: which name goes to which published port.
/// It is a pure value. `build` is the only place that decides the names, so
/// the result does not depend on the order of the Docker list.
struct DomainRoutes: Equatable, Sendable {
    struct Route: Equatable, Sendable {
        let containerID: String
        let containerName: String
        let containerPort: Int
        let hostPort: Int
        /// The port is published on `::1` only.
        var ipv6Only = false
        /// The proxy connects with TLS to the ports that speak TLS.
        var upstreamTLS: Bool { DomainPorts.tlsContainerPorts.contains(containerPort) }
    }

    enum Note: Equatable, Sendable {
        /// `name` is relative. `by` is the container that has the name.
        case taken(name: String, by: String)
        case labelPortNotPublished(Int)
        /// The port label is set but is not a port. The value is cut to 40 characters.
        case labelPortInvalid(String)
        /// The label port is a port that does not speak HTTP (a database), so the proxy ignores it.
        case labelPortNotWeb(Int)
        /// An entry of `dev.colimabar.domains` that gives no name.
        case nameDropped(String)
        /// The derived name lost non-ASCII characters. The text is the container, service or project name (cut to 40).
        case nameNotASCII(String)
        /// The derived name has no character left: the container gets no derived name.
        case nameEmpty
    }

    enum Resolution: Equatable, Sendable {
        case route(Route)
        /// Under our suffix, but no route ("" is the bare suffix).
        case unknown(relative: String)
        /// Not under any active suffix, or not a valid name.
        case foreign
        case vmStopped
    }

    /// Relative name to route.
    private(set) var routes: [String: Route] = [:]
    /// Container ID to its relative names, the primary one first.
    private(set) var names: [String: [String]] = [:]
    /// Compose project to its relative names, sorted.
    private(set) var projects: [String: [String]] = [:]
    /// Container ID to notes for the user.
    private(set) var notes: [String: [Note]] = [:]
    /// The host ports of every running candidate.
    private(set) var publishedHostPorts: Set<Int> = []
    private(set) var suffixes: [String] = [DomainName.localhost]
    private(set) var profile = ""
    private(set) var vmRunning = false
    /// The relative names that routes had while the VM ran (at most `rememberedCap`). They stay
    /// while the VM stops, for the same profile and suffixes, so HTTPS can
    /// show the 503 page of a stopped VM without a certificate warning.
    private(set) var rememberedNames: Set<String> = []

    static let rememberedCap = 256

    static let empty = DomainRoutes()

    /// Containers with at least one name.
    var count: Int { names.count }

    func primaryName(_ containerID: String) -> String? { names[containerID]?.first }

    /// One name that wants a route. Lower `priority` wins a collision.
    private struct Claim {
        let priority: Int
        let order: Int
        let relative: String
        let candidate: DomainCandidate
        let port: DomainCandidate.PortMap
        let primary: Bool
    }

    /// `otherPublished` holds the host ports of containers that are not candidates
    /// (internal ones, testcontainers). They count for `publishedHostPorts`.
    static func build(
        _ candidates: [DomainCandidate], suffixes: [String], profile: String, vmRunning: Bool,
        otherPublished: Set<Int> = [], previous: DomainRoutes = .empty, remember: Bool = true
    ) -> DomainRoutes {
        var table = DomainRoutes()
        table.suffixes = suffixes
        table.profile = profile
        table.vmRunning = vmRunning
        let sorted = candidates.sorted { ($0.created, $0.id) < ($1.created, $1.id) }
        table.publishedHostPorts = otherPublished.union(sorted.flatMap { $0.ports.map(\.hostPort) })

        var picked: [String: DomainCandidate.PortMap] = [:]
        for c in sorted {
            if c.domains == .off { continue }
            let choice = choose(c)
            if let port = choice.port { picked[c.id] = port }
            if !choice.notes.isEmpty { table.notes[c.id, default: []].append(contentsOf: choice.notes) }
            for piece in c.droppedEntries { table.notes[c.id, default: []].append(.nameDropped(piece)) }
        }

        var claims: [Claim] = []
        @discardableResult
        func add(
            _ priority: Int, _ order: Int, _ relative: String, _ c: DomainCandidate, _ port: DomainCandidate.PortMap,
            primary: Bool
        ) -> Bool {
            guard DomainName.isValidRelative(relative),
                relative.split(separator: ".").first.map(String.init) != DomainName.selfTestLabel
            else { return false }
            claims.append(
                Claim(priority: priority, order: order, relative: relative, candidate: c, port: port, primary: primary))
            return true
        }

        // Derived names. A replica group has two or more containers of one service.
        var groups: [String: [DomainCandidate]] = [:]
        var derived: [String: String] = [:]
        for c in sorted where c.domains != .off && picked[c.id] != nil {
            if let project = c.project.flatMap(DomainName.label), let service = c.service.flatMap(DomainName.label) {
                derived[c.id] = "\(service).\(project)"
                groups["\(project)/\(service)", default: []].append(c)
                for raw in [c.project, c.service].compactMap({ $0 }) where DomainName.lostCharacters(raw) {
                    table.notes[c.id, default: []].append(.nameNotASCII(String(raw.prefix(40))))
                }
            } else if let own = DomainName.label(c.name) {
                derived[c.id] = own
                if DomainName.lostCharacters(c.name) {
                    table.notes[c.id, default: []].append(.nameNotASCII(String(c.name.prefix(40))))
                }
            } else {
                table.notes[c.id, default: []].append(.nameEmpty)
            }
        }
        var replica: [String: (number: Int, plain: Bool, size: Int)] = [:]
        for (_, members) in groups where members.count >= 2 {
            let byName = members.sorted { $0.name < $1.name }
            var numbers: [(DomainCandidate, Int)] = []
            for (index, c) in byName.enumerated() {
                numbers.append((c, c.number ?? trailingNumber(c.name) ?? index + 1))
            }
            let lowest = numbers.map(\.1).min()
            var plainTaken = false
            for (c, n) in numbers {
                let plain = n == lowest && !plainTaken
                if plain { plainTaken = true }
                replica[c.id] = (n, plain, members.count)
            }
        }
        for (order, c) in sorted.enumerated() {
            guard let port = picked[c.id] else { continue }
            if let base = derived[c.id] {
                if let r = replica[c.id] {
                    let parts = base.split(separator: ".", maxSplits: 1).map(String.init)
                    // The label `<service>-<n>` must fit in 63 characters: cut the service part.
                    let tail = "-\(r.number)"
                    var service = String(parts[0].prefix(max(1, DomainName.maxLabel - tail.count)))
                    while service.hasSuffix("-") { service.removeLast() }
                    add(1, order, "\(service)\(tail).\(parts[1])", c, port, primary: true)
                    if r.plain { add(2, order, base, c, port, primary: false) }
                } else {
                    add(1, order, base, c, port, primary: true)
                }
            }
        }
        // Label names add to the derived ones. `.off` has none.
        for (order, c) in sorted.enumerated() {
            guard case .names(let entries) = c.domains else { continue }
            for e in entries {
                guard let relative = DomainName.relative(e.name, suffixes: suffixes) else {
                    table.notes[c.id, default: []].append(.nameDropped(String(e.name.prefix(60))))
                    continue
                }
                let port: DomainCandidate.PortMap?
                if let p = e.containerPort {
                    let found = c.ports.first { $0.containerPort == p }
                    if isNonWeb(p) || found.map({ isNonWeb($0.hostPort) }) == true {
                        table.notes[c.id, default: []].append(.labelPortNotWeb(p))
                        port = nil
                    } else {
                        if found == nil { table.notes[c.id, default: []].append(.labelPortNotPublished(p)) }
                        port = found
                    }
                } else {
                    port = picked[c.id]
                }
                if let port, !add(0, order, relative, c, port, primary: false) {
                    table.notes[c.id, default: []].append(.nameDropped(String(e.name.prefix(60))))
                }
            }
        }

        // The first claim of a name wins. Order: label, primary, plain, then the sorted candidates.
        var owners: [String: String] = [:]
        var won: [String: [Claim]] = [:]
        for claim in claims.sorted(by: { ($0.priority, $0.order) < ($1.priority, $1.order) }) {
            let c = claim.candidate
            if let owner = table.routes[claim.relative] {
                if owner.containerID != c.id {
                    table.notes[c.id, default: []].append(
                        .taken(name: claim.relative, by: owners[claim.relative] ?? owner.containerName))
                }
                continue
            }
            table.routes[claim.relative] = Route(
                containerID: c.id, containerName: c.name, containerPort: claim.port.containerPort,
                hostPort: claim.port.hostPort, ipv6Only: claim.port.ipv6Only)
            owners[claim.relative] = c.name
            won[c.id, default: []].append(claim)
        }

        // One note of a kind is enough, whatever the number of names that trigger it.
        for (id, list) in table.notes {
            var seen: [Note] = []
            for note in list where !seen.contains(note) { seen.append(note) }
            table.notes[id] = seen
        }

        // The derived primary comes first, then the names in claim order.
        for (id, list) in won {
            let ordered = list.filter(\.primary) + list.filter { !$0.primary }
            table.names[id] = ordered.map(\.relative)
        }
        var byProject: [String: Set<String>] = [:]
        for c in sorted {
            guard let project = c.project, let own = table.names[c.id] else { continue }
            byProject[project, default: []].formUnion(own)
        }
        table.projects = byProject.mapValues { $0.sorted() }
        if vmRunning {
            table.rememberedNames = Set(table.routes.keys.sorted().prefix(rememberedCap))
        } else if remember, previous.profile == profile, previous.suffixes == suffixes {
            table.rememberedNames = previous.rememberedNames
        }
        return table
    }

    private static func isNonWeb(_ port: Int) -> Bool { PortLink.nonWebPorts.contains(port) }

    /// The container port that a route uses. nil when there is none.
    static func pickPort(_ c: DomainCandidate) -> DomainCandidate.PortMap? { choose(c).port }

    /// The port of `c` and the notes about its port label. A label port that
    /// is a database port, or a bad label, gives a note and the automatic pick.
    /// A label port that no published port matches gives a note and no route.
    private static func choose(_ c: DomainCandidate) -> (port: DomainCandidate.PortMap?, notes: [Note]) {
        var notes: [Note] = []
        if let bad = c.labelPortInvalid { notes.append(.labelPortInvalid(bad)) }
        if let p = c.labelPort {
            if let m = c.ports.first(where: { $0.containerPort == p }) {
                if !isNonWeb(p), !isNonWeb(m.hostPort) { return (m, notes) }
                notes.append(.labelPortNotWeb(p))
            } else if isNonWeb(p) {
                notes.append(.labelPortNotWeb(p))
            } else {
                return (nil, notes + [.labelPortNotPublished(p)])
            }
        }
        for p in DomainPorts.preferred {
            if let m = c.ports.first(where: { $0.containerPort == p && !isNonWeb($0.hostPort) }) { return (m, notes) }
        }
        return (c.ports.first { !isNonWeb($0.containerPort) && !isNonWeb($0.hostPort) }, notes)
    }

    func resolve(host: String) -> Resolution {
        guard let normal = DomainName.normalizedHost(host),
            let relative = DomainName.relative(normal, suffixes: suffixes)
        else { return .foreign }
        guard vmRunning else { return .vmStopped }
        var name = relative
        while !name.isEmpty {
            if let r = routes[name] { return .route(r) }
            guard let dot = name.firstIndex(of: ".") else { break }
            name = String(name[name.index(after: dot)...])
        }
        return .unknown(relative: relative)
    }

    /// The number at the end of `web-2` or `shop_web_3`.
    private static func trailingNumber(_ name: String) -> Int? {
        let digits = name.reversed().prefix { $0.isNumber }
        guard !digits.isEmpty, digits.count < name.count else { return nil }
        let rest = name.dropLast(digits.count)
        guard rest.last == "-" || rest.last == "_" else { return nil }
        return Int(String(digits.reversed()))
    }
}

extension DomainRoutes {
    /// True when `host` is a route name or a subdomain of one. HTTPS makes a
    /// certificate only for such a name.
    func hasRoute(for host: String) -> Bool { routeHost(for: host) != nil }

    /// The full name of the route that serves `host`: the host itself or its
    /// closest parent that is a route. While the VM is stopped, a remembered
    /// name counts as a route. nil for any other host. HTTPS makes one
    /// certificate for each such name, so a flood of subdomains makes none more.
    func routeHost(for host: String) -> String? {
        guard let normal = DomainName.normalizedHost(host),
            let relative = DomainName.relative(normal, suffixes: suffixes), !relative.isEmpty
        else { return nil }
        var name = relative
        while !name.isEmpty {
            if vmRunning ? routes[name] != nil : rememberedNames.contains(name) {
                return String(normal.dropFirst(relative.count - name.count))
            }
            guard let dot = name.firstIndex(of: ".") else { break }
            name = String(name[name.index(after: dot)...])
        }
        return nil
    }
}
