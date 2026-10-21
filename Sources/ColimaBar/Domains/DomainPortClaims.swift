import Foundation

/// A container that publishes the port of the proxy since the proxy took it.
/// Lima forwards a published port once, when the container starts. If the proxy
/// held the port then, Lima failed and never tries again. The container needs a restart.
struct DomainRestartHint: Equatable, Sendable, Identifiable {
    let id: String
    let name: String
    let port: Int

    var text: String { Help.domainRestart(name: name, port: port) }
}

/// The host ports that the containers of the selected profile publish, by
/// container ID. A stopped container keeps its last ports, because the Docker
/// list gives no ports for it, and it claims them again when it starts. A
/// container that leaves the list (destroy) gives its ports back.
struct DomainPortClaims: Equatable, Sendable {
    private struct Entry: Equatable, Sendable {
        var name: String
        var ports: Set<Int>
        var running: Bool
    }

    private var entries: [String: Entry] = [:]

    /// The ports of every known container, running or stopped.
    var ports: Set<Int> { entries.values.reduce(into: []) { $0.formUnion($1.ports) } }

    /// Takes the list of `GET /containers/json?all=1`.
    mutating func update(_ list: [APIContainer]) {
        var next: [String: Entry] = [:]
        for c in list {
            let name = c.Names.first.map { String($0.drop { $0 == "/" }) }.flatMap { $0.isEmpty ? nil : $0 }
            if c.State == "running" {
                next[c.Id] = Entry(
                    name: name ?? String(c.Id.prefix(12)), ports: DomainCandidate.hostPorts(c), running: true)
            } else if var old = entries[c.Id] {
                old.running = false
                next[c.Id] = old
            }
        }
        entries = next
    }

    mutating func reset() { entries = [:] }

    func isRunning(_ id: String) -> Bool { entries[id]?.running ?? false }

    /// The running containers that publish `port`, by ID and name.
    func runningHolders(of port: Int) -> [(id: String, name: String)] {
        entries.filter { $0.value.running && $0.value.ports.contains(port) }
            .map { (id: $0.key, name: $0.value.name) }
            .sorted { $0.id < $1.id }
    }
}
