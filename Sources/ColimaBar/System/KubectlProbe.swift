import Foundation

/// All kubectl I/O of the context switchers. Each call runs `kubectl` with an
/// argument list and no shell. A call changes `current-context` or the
/// namespace of one context. It never adds, removes or renames a context,
/// a cluster or a user. KUBECONFIG is the inherited environment.
struct KubectlProbe: Sendable {
    var run: ContextRunner.Run = ContextRunner.system

    /// The kubeconfig, or nil if `kubectl config view` fails or gives no JSON.
    func read() async -> KubeConfig? {
        let r = await run(["kubectl", "config", "view", "-o", "json"], 10)
        return r.ok ? KubeConfig.parse(r.out) : nil
    }

    func useContext(_ name: String, among config: KubeConfig) async -> Bool {
        guard KubeConfig.isSafe(name), config.contexts.contains(where: { $0.name == name }) else { return false }
        return await run(["kubectl", "config", "use-context", name], 10).ok
    }

    /// Sets the namespace of the context `context`, by its name (not `--current`).
    /// It reads the kubeconfig again first: `set-context` makes a context that
    /// is missing, so a context that went away since the last read gets no write.
    func setNamespace(_ namespace: String, context: String) async -> Bool {
        guard KubeNamespace.isValid(namespace), KubeConfig.isSafe(context),
            let fresh = await read(), fresh.contexts.contains(where: { $0.name == context })
        else { return false }
        return await run(["kubectl", "config", "set-context", context, "--namespace=\(namespace)"], 10).ok
    }

    /// The namespaces of a Colima cluster whose VM runs, or nil. Other
    /// clusters are never contacted, and nothing runs for them.
    func namespaces(context: String, runningProfiles: Set<String>) async -> [String]? {
        guard KubeConfig.isSafe(context),
            KubeRules.mayListNamespaces(context: context, runningProfiles: runningProfiles)
        else { return nil }
        let r = await run(
            ["kubectl", "--context", context, "get", "namespaces", "-o", "name", "--request-timeout=3s"], 5)
        return r.ok ? KubeNamespace.parse(listing: r.out) : nil
    }
}
