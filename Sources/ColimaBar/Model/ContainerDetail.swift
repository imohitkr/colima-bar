import Foundation

/// What the Inspect page shows of one container. It holds raw environment
/// values, so it lives only in the state of the page. The model, the status
/// file and the diagnostics never get it.
struct ContainerDetail: Equatable, Sendable {
    struct HealthLine: Equatable, Sendable {
        let date: Date?
        let exitCode: Int
        /// One line, at most 200 characters.
        let output: String
    }
    struct Health: Equatable, Sendable {
        let status: String
        let failingStreak: Int
        /// The last 3 results, newest first.
        let log: [HealthLine]
    }
    struct Label: Equatable, Sendable {
        let key: String
        let value: String
        let isCompose: Bool
        let isSecret: Bool
    }
    struct Network: Equatable, Sendable {
        let name: String
        let ipv4: String
        let ipv6: String
        let aliases: [String]
    }
    struct Mount: Equatable, Sendable {
        let type: String
        /// The name of the volume for a volume, else the path of the source.
        let source: String
        let destination: String
        let readWrite: Bool
    }
    struct Port: Equatable, Sendable {
        let hostPort: Int
        let containerPort: Int
        let proto: String
        let hostIP: String
    }

    /// What one read of the container gives.
    enum Outcome: Equatable, Sendable {
        case found(ContainerDetail)
        /// Docker has no container with this ID.
        case gone
        /// No answer now: the VM is busy, stopped or on another profile.
        case unavailable
        /// Docker answered, but ColimaBar could not use the answer. The text
        /// names the HTTP status or the kind of decoding error, never a value.
        case failed(String)
    }

    static let healthOutputLimit = 200
    static let maxHealthLines = 3

    let id: String
    let name: String
    let imageRef: String
    let imageID: String
    /// `RepoDigests` of the image, for example `nginx@sha256:…`.
    let digests: [String]

    let status: String
    let exitCode: Int
    let oomKilled: Bool
    let error: String
    /// nil for a date that Docker leaves at zero.
    let created: Date?
    let started: Date?
    let finished: Date?
    /// "none", "always", "unless-stopped", "on-failure" or "on-failure:5".
    let restartPolicy: String
    let restartCount: Int
    let health: Health?

    let entrypoint: [String]
    let command: [String]
    let workingDir: String
    let user: String
    let env: [EnvEntry]
    let labels: [Label]

    let networks: [Network]
    let mounts: [Mount]
    let ports: [Port]

    /// Bytes. 0 means no limit.
    let memoryLimit: Int64
    let memoryReservation: Int64
    /// 0 means no limit.
    let cpus: Double
    let cpuShares: Int64
    /// 0 or less means no limit.
    let pidsLimit: Int64
    let privileged: Bool

    /// The `sha256:` part of the first digest, or nil.
    var digest: String? {
        digests.lazy.compactMap { $0.split(separator: "@", maxSplits: 1).last.map(String.init) }.first
    }

    static func make(from api: APIContainerDetail, digests: [String]) -> ContainerDetail {
        let state = api.State
        let host = api.HostConfig
        let cfg = api.Config
        let policy = host?.RestartPolicy
        return ContainerDetail(
            id: api.Id, name: String((api.Name ?? "").drop { $0 == "/" }),
            imageRef: cfg?.Image ?? "", imageID: api.Image ?? "", digests: digests,
            status: state?.Status ?? "", exitCode: state?.ExitCode ?? 0, oomKilled: state?.OOMKilled ?? false,
            error: state?.Error ?? "",
            created: date(api.Created), started: date(state?.StartedAt), finished: date(state?.FinishedAt),
            restartPolicy: restartText(policy), restartCount: api.RestartCount ?? 0,
            health: health(state?.Health),
            entrypoint: cfg?.Entrypoint?.values ?? [], command: cfg?.Cmd?.values ?? [],
            workingDir: cfg?.WorkingDir ?? "", user: cfg?.User ?? "",
            env: EnvMask.entries(cfg?.Env ?? []), labels: labels(cfg?.Labels ?? [:]),
            networks: networks(api.NetworkSettings?.Networks ?? [:], id: api.Id),
            mounts: (api.Mounts ?? []).map { m in
                let type = m.`Type` ?? ""
                let source = type == "volume" ? (m.Name ?? m.Source ?? "") : (m.Source ?? "")
                return Mount(type: type, source: source, destination: m.Destination ?? "", readWrite: m.RW ?? true)
            },
            ports: ports(api.NetworkSettings?.Ports ?? [:]),
            memoryLimit: host?.Memory ?? 0, memoryReservation: host?.MemoryReservation ?? 0,
            cpus: Double(host?.NanoCpus ?? 0) / 1e9, cpuShares: host?.CpuShares ?? 0,
            pidsLimit: host?.PidsLimit ?? 0, privileged: host?.Privileged ?? false)
    }

    // MARK: - Parts

    /// nil for no text, for a bad text and for Docker's zero date.
    private static func date(_ text: String?) -> Date? {
        guard let text, !text.hasPrefix("0001-"), let t = LogTime.parse(Substring(text)) else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(t.secs) + TimeInterval(t.nanos) / 1e9)
    }

    private static func restartText(_ p: APIContainerDetail.RestartPolicy?) -> String {
        guard let name = p?.Name, !name.isEmpty else { return "none" }
        if name == "on-failure", let n = p?.MaximumRetryCount, n > 0 { return "on-failure:\(n)" }
        return name
    }

    private static func health(_ h: APIContainerDetail.Health?) -> Health? {
        guard let h, let status = h.Status, !status.isEmpty else { return nil }
        let lines = (h.Log ?? []).suffix(maxHealthLines).reversed().map { e in
            HealthLine(
                date: date(e.Start), exitCode: e.ExitCode ?? 0,
                output: oneLine(e.Output ?? "", limit: healthOutputLimit))
        }
        return Health(status: status, failingStreak: h.FailingStreak ?? 0, log: lines)
    }

    /// The text on one line: line breaks and runs of spaces become one space.
    static func oneLine(_ text: String, limit: Int) -> String {
        let flat = text.split(whereSeparator: { $0.isNewline || $0 == "\t" || $0 == " " }).joined(separator: " ")
        return flat.count > limit ? String(flat.prefix(limit)) + "…" : flat
    }

    /// Compose labels first, then the others, each group by key.
    private static func labels(_ all: [String: String]) -> [Label] {
        all.map { key, value in
            Label(
                key: key, value: value, isCompose: key.hasPrefix("com.docker.compose."),
                isSecret: EnvMask.isSecret(key: key, value: value))
        }
        .sorted { a, b in a.isCompose != b.isCompose ? a.isCompose : a.key < b.key }
    }

    /// The aliases are `Aliases` and `DNSNames` without duplicates. Docker
    /// adds the short ID of the container as an alias, so it falls away.
    private static func networks(_ all: [String: APIContainerDetail.Endpoint], id: String) -> [Network] {
        let short = String(id.prefix(12))
        return all.map { name, e in
            var seen = Set<String>()
            let names = ((e.Aliases ?? []) + (e.DNSNames ?? [])).filter { $0 != short && seen.insert($0).inserted }
            return Network(
                name: name, ipv4: e.IPAddress ?? "", ipv6: e.GlobalIPv6Address ?? "", aliases: names)
        }
        .sorted { $0.name < $1.name }
    }

    /// One row for each published binding, by host port. `"80/tcp"` is the
    /// key. A port with no binding is not published and has no row. Docker
    /// lists a port on all addresses twice (`0.0.0.0` and `::`): one row.
    static func ports(_ all: [String: [APIContainerDetail.Binding]?]) -> [Port] {
        var rows: [Port] = []
        var allAddresses = Set<String>()
        for (key, bindings) in all {
            let parts = key.split(separator: "/", maxSplits: 1).map(String.init)
            guard let container = parts.first.flatMap({ Int($0) }) else { continue }
            for b in bindings ?? [] {
                guard let host = b.HostPort.flatMap({ Int($0) }) else { continue }
                let ip = b.HostIp ?? ""
                if ["", "0.0.0.0", "::"].contains(ip) {
                    let key = "\(host)/\(container)/\(parts.count > 1 ? parts[1] : "tcp")"
                    guard allAddresses.insert(key).inserted else { continue }
                }
                rows.append(
                    Port(
                        hostPort: host, containerPort: container, proto: parts.count > 1 ? parts[1] : "tcp",
                        hostIP: b.HostIp ?? ""))
            }
        }
        return rows.sorted {
            ($0.hostPort, $0.proto, $0.hostIP, $0.containerPort) < ($1.hostPort, $1.proto, $1.hostIP, $1.containerPort)
        }
    }
}
