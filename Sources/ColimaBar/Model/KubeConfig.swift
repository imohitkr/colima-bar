import Foundation

/// The part of the kubeconfig that the switcher shows. It comes from
/// `kubectl config view -o json`, which reads local files and hides secrets.
struct KubeConfig: Equatable, Sendable {
    struct Context: Equatable, Sendable {
        let name: String
        let cluster: String
        /// The namespace of the context. `default` when the context sets none.
        let namespace: String
    }

    var current: String?
    var contexts: [Context]

    var currentContext: Context? { contexts.first { $0.name == current } }

    /// The namespaces that the kubeconfig names, sorted.
    var namespaces: [String] { Array(Set(contexts.map(\.namespace))).sorted() }

    /// A name that kubectl could read as an option, or that is empty.
    static func isSafe(_ name: String) -> Bool {
        !name.isEmpty && !name.hasPrefix("-") && !name.contains("\n")
    }

    /// The config of the JSON text, or nil if it is not a kubeconfig view.
    static func parse(_ text: String) -> KubeConfig? {
        guard let root = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] else {
            return nil
        }
        let entries = root["contexts"] as? [[String: Any]] ?? []
        let contexts = entries.compactMap { entry -> Context? in
            guard let name = entry["name"] as? String, isSafe(name) else { return nil }
            let body = entry["context"] as? [String: Any]
            let namespace = (body?["namespace"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "default"
            return Context(name: name, cluster: body?["cluster"] as? String ?? "", namespace: namespace)
        }
        let current = (root["current-context"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return KubeConfig(current: current, contexts: contexts)
    }
}
