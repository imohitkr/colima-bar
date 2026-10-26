import Foundation

/// Order, visibility and labels of the context menus. Pure, so tests need no UI.
enum ContextMenuRules {
    struct Entry: Equatable, Sendable, Identifiable {
        let name: String
        let title: String
        let isCurrent: Bool
        var id: String { name }
    }

    /// The longest description in a title.
    static let descriptionLimit = 48

    /// The docker contexts to offer. Ours come first: `colimabar` (the
    /// selected profile), then `colimabar-PROFILE`. The rest follow by name.
    /// While auto-start is on, the Colima contexts are hidden: ColimaBar would
    /// move the CLI back to the ColimaBar context of the same daemon.
    static func dockerEntries(
        items: [DockerContextItem], current: String, selected: String, autoStart: Bool
    ) -> [Entry] {
        let now = current.isEmpty ? "default" : current
        func entry(_ item: DockerContextItem) -> Entry {
            Entry(name: item.name, title: title(item, selected: selected), isCurrent: item.name == now)
        }
        let visible = items.filter { item in
            if case .colima = item.kind { return !autoStart }
            return true
        }
        let own = visible.filter { $0.kind == .own }
        let profiles = visible.filter { if case .ownProfile = $0.kind { true } else { false } }
            .sorted { $0.name < $1.name }
        let rest = visible.filter { item in !own.contains(item) && !profiles.contains(item) }
            .sorted { $0.name < $1.name }
        return (own + profiles + rest).map(entry)
    }

    private static func title(_ item: DockerContextItem, selected: String) -> String {
        if item.kind == .own { return "\(item.name) — selected profile (\(selected))" }
        if case .ownProfile = item.kind { return item.name }
        let line = item.description.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let text = line.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return item.name }
        let short = text.count > descriptionLimit ? String(text.prefix(descriptionLimit - 1)) + "…" : text
        return "\(item.name) — \(short)"
    }

    /// The label of the docker context row: the current context.
    static func currentLabel(_ current: String) -> String {
        current.isEmpty ? "default" : shortened(current, to: nameLimit)
    }

    /// The longest context name in a row label. The popover has a fixed width.
    static let nameLimit = 28
    /// The longest namespace in a row label.
    static let namespaceLimit = 20

    /// `text` with its middle cut to "…" if it is longer than `limit`. Both
    /// ends stay: cloud context names differ at the end.
    static func shortened(_ text: String, to limit: Int) -> String {
        guard text.count > limit else { return text }
        let tail = (limit - 1) / 2
        let head = limit - 1 - tail
        return String(text.prefix(head)) + "…" + String(text.suffix(tail))
    }

    /// The kubectl contexts to offer, in kubeconfig order.
    static func kubeEntries(_ config: KubeConfig) -> [Entry] {
        config.contexts.map { Entry(name: $0.name, title: $0.name, isCurrent: $0.name == config.current) }
    }

    /// The namespaces to offer for the current context: the current one, the
    /// ones that a cluster listed and the ones that the kubeconfig names.
    static func namespaceEntries(current: String, listed: [String]?, config: KubeConfig) -> [Entry] {
        let names = Set([current] + (listed ?? []) + config.namespaces).filter(KubeNamespace.isValid).sorted()
        return names.map { Entry(name: $0, title: $0, isCurrent: $0 == current) }
    }

    /// The text of the kubectl row: `kubectl: CONTEXT · NAMESPACE`. `failed`
    /// tells a read that failed from a read that has not finished.
    static func kubeLabel(_ config: KubeConfig?, failed: Bool) -> String {
        guard let config else {
            return failed ? "kubectl: cannot read the kubeconfig" : "kubectl: reading the kubeconfig…"
        }
        guard let context = config.currentContext else { return "kubectl: no current context" }
        return
            "kubectl: \(shortened(context.name, to: nameLimit)) · \(shortened(context.namespace, to: namespaceLimit))"
    }
}
