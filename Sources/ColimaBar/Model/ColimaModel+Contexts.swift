import Foundation

/// The context switchers: the docker context and, if the user wants it, the
/// kubectl context and namespace. A switch happens only after a click. The
/// lists read files or run local `kubectl` calls. Only the namespace list of a
/// Colima cluster whose VM runs contacts a cluster. A debug run switches
/// nothing and lists no namespace.
extension ColimaModel {
    /// A Colima cluster lists its namespaces at most this often (seconds).
    static let namespaceListGap: TimeInterval = 30

    // MARK: - Docker

    /// The context that the user picked in ColimaBar and that is not one of
    /// ColimaBar or Colima, or nil. `Routing.contextTarget` returns to it after `colima start`.
    var dockerContextChoice: String? {
        get { domainsStore.string(forKey: Defaults.Key.dockerContextChoice.rawValue) }
        set {
            // A debug run never writes a setting.
            guard !isDebug, newValue != dockerContextChoice else { return }
            if let newValue {
                domainsStore.set(newValue, forKey: Defaults.Key.dockerContextChoice.rawValue)
            } else {
                domainsStore.removeObject(forKey: Defaults.Key.dockerContextChoice.rawValue)
            }
        }
    }

    var dockerContextEntries: [ContextMenuRules.Entry] {
        ContextMenuRules.dockerEntries(
            items: dockerContexts, current: dockerContextCurrent, selected: profile, autoStart: autoStart)
    }

    /// Reads the context folder and the current context. It starts no process
    /// and contacts no daemon. It also drops a pick that is stale: a ColimaBar
    /// context is current (the user switched back), or the context is gone.
    func refreshDockerContexts() {
        guard !contextsFixtureLoaded else { return }
        let items = DockerContextStore.list(configDir: dockerConfigDir)
        let current = Routing.currentContext(path: "\(dockerConfigDir)/config.json") ?? ""
        setDockerContexts(items, current: current)
        dockerContextChoice = Routing.keptChoice(
            dockerContextChoice, current: current, existing: Set(items.map(\.name)))
    }

    /// Switches the docker CLI to `name`. A pick of `default` or another
    /// foreign context becomes the choice that survives `colima start`. A
    /// pick of a ColimaBar or Colima context removes the choice.
    @discardableResult
    func switchDockerContext(to name: String) async -> Bool {
        guard !isDebug else { return false }
        guard await DockerContextStore.use(name, among: dockerContexts, run: contextRunner) else {
            log.error("docker context use failed or was refused for a pick")
            notify("ColimaBar could not switch the docker context to \(name). See the log.")
            return false
        }
        let foreign = dockerContexts.first { $0.name == name }?.isForeign ?? false
        dockerContextChoice = foreign ? name : nil
        log.notice("switched the docker context to \(name, privacy: .public) (menu)")
        refreshDockerContexts()
        return true
    }

    // MARK: - kubectl

    /// The kubectl switchers show: kubectl exists and the setting is on.
    var showsKubectl: Bool { kubectlAvailable && kubectlSwitcher }

    var kubeProbe: KubectlProbe { KubectlProbe(run: contextRunner) }

    var kubeContextEntries: [ContextMenuRules.Entry] {
        kubeConfig.map(ContextMenuRules.kubeEntries) ?? []
    }

    var kubeNamespaceEntries: [ContextMenuRules.Entry] {
        guard let config = kubeConfig, let context = config.currentContext else { return [] }
        return ContextMenuRules.namespaceEntries(
            current: context.namespace, listed: kubeNamespaces[context.name], config: config)
    }

    /// Looks for kubectl and, if the switchers show, reads the kubeconfig and
    /// lists the namespaces of the current Colima cluster. With kubectl
    /// missing or the setting off, it forgets everything and runs nothing.
    func refreshKube() async {
        guard !contextsFixtureLoaded else { return }
        setKube(available: kubectlLocator() != nil)
        guard showsKubectl else {
            setKube(config: .some(nil), readFailed: false)
            return
        }
        let config = await kubeProbe.read()
        guard showsKubectl else { return }
        setKube(config: .some(config), readFailed: config == nil)
        await refreshKubeNamespaces(running: Set(profiles.filter(\.isRunning).map(\.name)))
    }

    /// Lists the namespaces of the current context, only for a Colima cluster
    /// whose VM runs, and at most once in `namespaceListGap` seconds.
    func refreshKubeNamespaces(running: Set<String>) async {
        guard !isDebug, let context = kubeConfig?.current else { return }
        guard KubeRules.mayListNamespaces(context: context, runningProfiles: running) else { return }
        let now = Date()
        if let last = kubeNamespaceAt[context], now.timeIntervalSince(last) < Self.namespaceListGap { return }
        kubeNamespaceAt[context] = now
        guard let names = await kubeProbe.namespaces(context: context, runningProfiles: running) else { return }
        setKube(namespaces: kubeNamespaces.merging([context: names]) { $1 })
    }

    @discardableResult
    func switchKubeContext(to name: String) async -> Bool {
        guard !isDebug, showsKubectl, let config = kubeConfig else { return false }
        guard await kubeProbe.useContext(name, among: config) else {
            log.error("kubectl config use-context failed or was refused for a pick")
            notify("ColimaBar could not switch the kubectl context to \(name). See the log.")
            return false
        }
        log.notice("switched the kubectl context to \(name, privacy: .public) (menu)")
        await refreshKube()
        return true
    }

    /// Sets the namespace of the current kubectl context.
    @discardableResult
    func setKubeNamespace(_ namespace: String) async -> Bool {
        guard !isDebug, showsKubectl, let context = kubeConfig?.current else { return false }
        guard await kubeProbe.setNamespace(namespace, context: context) else {
            log.error("kubectl config set-context failed or was refused for a namespace")
            notify("ColimaBar could not set the namespace of \(context) to \(namespace). See the log.")
            return false
        }
        log.notice("set the namespace of the kubectl context \(context, privacy: .public) (menu)")
        await refreshKube()
        return true
    }

    // MARK: - Debug fixture

    /// Debug runs only: shows the contexts of `COLIMABAR_CONTEXTS_FIXTURE`
    /// instead of the real ones, and turns the kubectl row on in memory.
    /// Returns false in a normal run, or when the data is not a fixture.
    @discardableResult
    func loadContextsFixture(_ data: Data) -> Bool {
        guard isDebug, let fixture = try? JSONDecoder().decode(ContextsFixture.self, from: data) else { return false }
        contextsFixtureLoaded = true
        if let docker = fixture.docker { setDockerContexts(fixture.dockerItems, current: docker.current) }
        if let config = fixture.kubeConfig {
            kubectlSwitcher = true
            setKube(available: true, config: .some(config), namespaces: fixture.kube?.namespaces ?? [:])
        }
        return true
    }
}
