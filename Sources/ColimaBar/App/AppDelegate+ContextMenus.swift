import AppKit

/// The context items of the right-click menu: Docker Context, and, when the
/// kubectl switchers show, Kubernetes Context and Namespace. A pick runs only
/// after a click. In a debug run each item is disabled.
extension AppDelegate {
    func addContextItems(to menu: NSMenu) {
        // The menu shows what the last read found. The reads below are for the next open.
        model.refreshDockerContexts()
        Task { await model.refreshKube() }
        menu.addItem(.separator())
        menu.addItem(
            submenu(
                "Docker Context", entries: model.dockerContextEntries, action: #selector(pickDockerContext(_:)),
                hint: Help.dockerContextMenu))
        guard model.showsKubectl, model.kubeConfig != nil else { return }
        menu.addItem(
            submenu(
                "Kubernetes Context", entries: model.kubeContextEntries, action: #selector(pickKubeContext(_:)),
                hint: Help.kubeContext))
        // A namespace belongs to the current context. Each item keeps the context that this menu showed.
        guard let context = model.kubeConfig?.current else { return }
        let namespaces = submenu(
            "Kubernetes Namespace", entries: model.kubeNamespaceEntries, action: #selector(pickKubeNamespace(_:)),
            hint: Help.kubeNamespace, represent: { [context, $0.name] })
        let other = NSMenuItem(title: "Other…", action: #selector(askKubeNamespace(_:)), keyEquivalent: "")
        other.target = self
        other.representedObject = context
        other.isEnabled = !model.isDebug
        namespaces.submenu?.addItem(.separator())
        namespaces.submenu?.addItem(other)
        menu.addItem(namespaces)
    }

    private func submenu(
        _ title: String, entries: [ContextMenuRules.Entry], action: Selector, hint: String,
        represent: (ContextMenuRules.Entry) -> Any = { $0.name }
    ) -> NSMenuItem {
        let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        parent.toolTip = model.isDebug ? Help.contextDebug : hint
        let menu = NSMenu(title: title)
        // Else AppKit enables each item that has a target and an action, and a debug run could pick.
        menu.autoenablesItems = false
        for entry in entries {
            let item = NSMenuItem(title: entry.title, action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = represent(entry)
            item.state = entry.isCurrent ? .on : .off
            item.isEnabled = !model.isDebug
            menu.addItem(item)
        }
        parent.submenu = menu
        return parent
    }

    @objc func pickDockerContext(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        Task { await model.switchDockerContext(to: name) }
    }

    @objc func pickKubeContext(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        Task { await model.switchKubeContext(to: name) }
    }

    @objc func pickKubeNamespace(_ sender: NSMenuItem) {
        guard let pick = sender.representedObject as? [String], pick.count == 2 else { return }
        Task { await model.setKubeNamespace(pick[1], context: pick[0]) }
    }

    @objc func askKubeNamespace(_ sender: NSMenuItem) {
        guard let context = sender.representedObject as? String else { return }
        KubeNamespaceAlert.ask(model: model, context: context)
    }
}
