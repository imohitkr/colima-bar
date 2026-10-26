import Testing

@testable import ColimaBar

@Suite struct ContextMenuRulesTests {
    private func item(_ name: String, _ description: String = "") -> DockerContextItem {
        DockerContextItem(name: name, description: description, endpoint: "")
    }

    private let all = ["remote", "colima", "colimabar-work", "default", "colimabar", "colima-work"]

    private func entries(autoStart: Bool, current: String = "colimabar") -> [ContextMenuRules.Entry] {
        ContextMenuRules.dockerEntries(
            items: all.map { item($0) }, current: current, selected: "dev", autoStart: autoStart)
    }

    @Test func ownContextsComeFirst() {
        #expect(entries(autoStart: true).map(\.name) == ["colimabar", "colimabar-work", "default", "remote"])
    }

    @Test func colimaContextsShowOnlyWhileAutoStartIsOff() {
        #expect(entries(autoStart: true).map(\.name).contains("colima") == false)
        #expect(
            entries(autoStart: false).map(\.name) == [
                "colimabar", "colimabar-work", "colima", "colima-work", "default", "remote",
            ])
    }

    @Test func theOwnContextNamesTheSelectedProfile() {
        #expect(entries(autoStart: true)[0].title == "colimabar — selected profile (dev)")
        #expect(entries(autoStart: true)[1].title == "colimabar-work")
    }

    @Test func theCurrentContextIsChecked() {
        #expect(entries(autoStart: true, current: "remote").filter(\.isCurrent).map(\.name) == ["remote"])
    }

    @Test func anEmptyCurrentContextMeansDefault() {
        #expect(entries(autoStart: true, current: "").filter(\.isCurrent).map(\.name) == ["default"])
        #expect(ContextMenuRules.currentLabel("") == "default")
        #expect(ContextMenuRules.currentLabel("remote") == "remote")
    }

    @Test func aTitleHasTheFirstLineOfTheDescriptionCutShort() {
        let long = String(repeating: "x", count: 80)
        let list = ContextMenuRules.dockerEntries(
            items: [item("a", "Work box\nsecond line"), item("b", long), item("c")], current: "", selected: "dev",
            autoStart: true)
        #expect(list[0].title == "a — Work box")
        #expect(list[1].title.count == "b — ".count + ContextMenuRules.descriptionLimit)
        #expect(list[1].title.hasSuffix("…"))
        #expect(list[2].title == "c")
    }

    @Test func kubeEntriesKeepTheKubeconfigOrderAndCheckTheCurrentContext() {
        let config = KubeConfig(
            current: "b",
            contexts: [
                .init(name: "z", cluster: "", namespace: "default"),
                .init(name: "b", cluster: "", namespace: "default"),
            ])
        let list = ContextMenuRules.kubeEntries(config)
        #expect(list.map(\.name) == ["z", "b"])
        #expect(list.map(\.isCurrent) == [false, true])
    }

    @Test func namespaceEntriesJoinTheCurrentTheListedAndTheConfiguredNames() {
        let config = KubeConfig(
            current: "c",
            contexts: [
                .init(name: "c", cluster: "", namespace: "shop"), .init(name: "d", cluster: "", namespace: "blog"),
            ])
        let list = ContextMenuRules.namespaceEntries(
            current: "shop", listed: ["default", "kube-system"], config: config)
        #expect(list.map(\.name) == ["blog", "default", "kube-system", "shop"])
        #expect(list.filter(\.isCurrent).map(\.name) == ["shop"])
        let offline = ContextMenuRules.namespaceEntries(current: "shop", listed: nil, config: config)
        #expect(offline.map(\.name) == ["blog", "shop"])
    }

    @Test func aLongNameKeepsItsBothEndsInTheRowLabel() {
        #expect(ContextMenuRules.shortened("short", to: 10) == "short")
        let name = "arn:aws:eks:eu-central-1:123456789012:cluster/production-main"
        let short = ContextMenuRules.shortened(name, to: ContextMenuRules.nameLimit)
        #expect(short.count == ContextMenuRules.nameLimit)
        #expect(short.hasPrefix("arn:aws:eks") && short.hasSuffix("production-main") == false)
        #expect(short.hasSuffix("ion-main"))
        #expect(ContextMenuRules.currentLabel(name) == short)
        let config = KubeConfig(current: name, contexts: [.init(name: name, cluster: "", namespace: "ns")])
        #expect(ContextMenuRules.kubeLabel(config, failed: false) == "kubectl: \(short) · ns")
    }

    @Test func aLongestNamespaceIsShortenedInTheRowLabel() {
        let namespace = String(repeating: "a", count: 31) + "-" + String(repeating: "z", count: 31)
        #expect(namespace.count == 63)
        let config = KubeConfig(current: "c", contexts: [.init(name: "c", cluster: "", namespace: namespace)])
        let short = ContextMenuRules.shortened(namespace, to: ContextMenuRules.namespaceLimit)
        #expect(short.count == ContextMenuRules.namespaceLimit)
        #expect(ContextMenuRules.kubeLabel(config, failed: false) == "kubectl: c · \(short)")
    }

    @Test func theKubeLabelShowsContextAndNamespaceOrTheProblem() {
        let config = KubeConfig(current: "c", contexts: [.init(name: "c", cluster: "", namespace: "shop")])
        #expect(ContextMenuRules.kubeLabel(config, failed: false) == "kubectl: c · shop")
        #expect(ContextMenuRules.kubeLabel(nil, failed: true) == "kubectl: cannot read the kubeconfig")
        #expect(ContextMenuRules.kubeLabel(nil, failed: false) == "kubectl: reading the kubeconfig…")
        #expect(
            ContextMenuRules.kubeLabel(KubeConfig(current: nil, contexts: []), failed: false)
                == "kubectl: no current context")
    }
}
