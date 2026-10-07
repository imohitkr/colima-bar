import Foundation
import os

/// The docker contexts `colimabar-PROFILE`. Each one points at the proxy
/// socket of its profile, so `docker --context colimabar-work ps` starts the
/// `work` profile when it is stopped.
///
/// ColimaBar changes only contexts that it created: their description
/// starts with "ColimaBar". It never touches other contexts. The `colimabar`
/// context of the stable socket is managed by `Routing`.
@MainActor
enum ProfileContexts {
    private static let log = Logger(category: "routing")
    nonisolated static let prefix = "colimabar-"

    nonisolated static func name(_ profile: String) -> String { prefix + profile }

    nonisolated static func description(_ profile: String) -> String {
        "ColimaBar profile \(profile) (auto-starts Colima)"
    }

    /// True for a context that ColimaBar created.
    nonisolated static func isOurs(_ context: Context) -> Bool { context.description.hasPrefix("ColimaBar") }

    /// One row of `docker context ls`.
    struct Context: Equatable, Sendable {
        let name: String
        let endpoint: String
        let description: String
    }

    /// One docker CLI call.
    enum Step: Equatable, Sendable {
        case create(name: String, host: String, description: String)
        case update(name: String, host: String)
        case remove(name: String)
    }

    /// The `--format` of `docker context ls`. The description is last,
    /// because it is free text.
    nonisolated static let listFormat = "{{.Name}}\t{{.DockerEndpoint}}\t{{.Description}}"

    nonisolated static func parse(_ out: String) -> [Context] {
        out.split(separator: "\n").compactMap { line in
            let f = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
            guard f.count >= 2, !f[0].isEmpty else { return nil }
            return Context(name: f[0], endpoint: f[1], description: f.count > 2 ? f[2] : "")
        }
    }

    /// The calls that make the `colimabar-*` contexts match `wanted`
    /// (profile to docker host). It creates missing contexts, updates ours
    /// that point elsewhere and removes ours whose profile is not wanted.
    /// A context with the same name that ColimaBar did not create stays.
    nonisolated static func plan(existing: [Context], wanted: [String: String]) -> [Step] {
        let byName = Dictionary(existing.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        var steps: [Step] = []
        for (profile, host) in wanted.sorted(by: { $0.key < $1.key }) {
            let n = name(profile)
            if let c = byName[n] {
                if isOurs(c), c.endpoint != host { steps.append(.update(name: n, host: host)) }
            } else {
                steps.append(.create(name: n, host: host, description: description(profile)))
            }
        }
        let wantedNames = Set(wanted.keys.map(name))
        for c in existing.sorted(by: { $0.name < $1.name })
        where c.name.hasPrefix(prefix) && isOurs(c) && !wantedNames.contains(c.name) {
            steps.append(.remove(name: c.name))
        }
        return steps
    }

    /// The docker CLI arguments of a step.
    nonisolated static func arguments(_ step: Step) -> [String] {
        switch step {
        case .create(let n, let host, let d):
            ["docker", "context", "create", n, "--description", d, "--docker", "host=\(host)"]
        case .update(let n, let host):
            ["docker", "context", "update", n, "--docker", "host=\(host)"]
        case .remove(let n):
            ["docker", "context", "rm", "-f", n]
        }
    }

    /// Makes the contexts match `wanted`. Returns false if the docker CLI
    /// could not list the contexts, for example when it is not installed.
    static func apply(wanted: [String: String]) async -> Bool {
        let ls = await Shell.run(["docker", "context", "ls", "--format", listFormat], timeout: 10)
        guard ls.ok else { return false }
        let steps = plan(existing: parse(ls.out), wanted: wanted)
        await run(steps)
        return true
    }

    /// Removes the context of one profile, if ColimaBar created it.
    static func remove(profile: String) async {
        let ls = await Shell.run(["docker", "context", "ls", "--format", listFormat], timeout: 10)
        guard ls.ok,
            let c = parse(ls.out).first(where: { $0.name == name(profile) }), isOurs(c)
        else { return }
        await run([.remove(name: c.name)])
    }

    private static func run(_ steps: [Step]) async {
        guard !steps.isEmpty else { return }
        var current: String?
        if steps.contains(where: { if case .remove = $0 { true } else { false } }) {
            current = await Shell.run(["docker", "context", "show"], timeout: 5).out
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        for step in steps {
            // The docker CLI cannot remove the current context. Use the
            // context of the stable socket instead.
            if case .remove(let n) = step, n == current {
                _ = await Shell.run(["docker", "context", "use", Routing.contextName], timeout: 10)
            }
            let r = await Shell.run(arguments(step), timeout: 10)
            if r.ok {
                log.info(
                    "docker context: \(arguments(step).dropFirst(2).prefix(2).joined(separator: " "), privacy: .public)"
                )
            } else {
                log.error(
                    "docker context step failed (exit \(r.status)): \(String(describing: step), privacy: .public)")
            }
        }
    }
}
