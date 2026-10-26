import Foundation

/// The file of `COLIMABAR_CONTEXTS_FIXTURE`. A debug run shows its contexts
/// instead of the real ones. For screenshots.
///
///     {"docker": {"current": "colimabar", "contexts": [{"name": "colimabar", "description": "ColimaBar"}]},
///      "kube": {"current": "colima", "contexts": [{"name": "colima", "namespace": "shop"}],
///               "namespaces": {"colima": ["default", "shop"]}}}
struct ContextsFixture: Decodable {
    struct DockerContext: Decodable {
        let name: String
        let description: String?
        let endpoint: String?
    }
    struct Docker: Decodable {
        let current: String
        let contexts: [DockerContext]
    }
    struct KubeContext: Decodable {
        let name: String
        let namespace: String?
        let cluster: String?
    }
    struct Kube: Decodable {
        let current: String?
        let contexts: [KubeContext]
        let namespaces: [String: [String]]?
    }

    let docker: Docker?
    let kube: Kube?

    var dockerItems: [DockerContextItem] {
        (docker?.contexts ?? []).filter { DockerContextStore.isSafe($0.name) }
            .map { DockerContextItem(name: $0.name, description: $0.description ?? "", endpoint: $0.endpoint ?? "") }
    }

    var kubeConfig: KubeConfig? {
        guard let kube else { return nil }
        let contexts = kube.contexts.filter { KubeConfig.isSafe($0.name) }
            .map { KubeConfig.Context(name: $0.name, cluster: $0.cluster ?? "", namespace: $0.namespace ?? "default") }
        return KubeConfig(current: kube.current, contexts: contexts)
    }
}
