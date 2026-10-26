import Testing

@testable import ColimaBar

@Suite struct KubectlProbeTests {
    private let config = KubeConfig(
        current: "colima",
        contexts: [
            .init(name: "colima", cluster: "colima", namespace: "default"),
            .init(name: "prod", cluster: "prod", namespace: "shop"),
        ])

    @Test func readRunsConfigViewAndParsesTheJSON() async {
        let calls = Recorder()
        let args = ["kubectl", "config", "view", "-o", "json"]
        let json = #"{"current-context":"prod","contexts":[{"name":"prod","context":{"namespace":"shop"}}]}"#
        let read = await KubectlProbe(run: calls.run(out: [args: json])).read()
        #expect(read?.current == "prod")
        #expect(calls.all == [args])
    }

    @Test func readIsNilWhenKubectlFails() async {
        #expect(await KubectlProbe(run: Recorder().run(status: 1)).read() == nil)
    }

    @Test func useContextRunsUseContextByName() async {
        let calls = Recorder()
        #expect(await KubectlProbe(run: calls.run()).useContext("prod", among: config))
        #expect(calls.all == [["kubectl", "config", "use-context", "prod"]])
    }

    @Test func useContextRefusesAnUnknownOrOptionLikeName() async {
        let calls = Recorder()
        let probe = KubectlProbe(run: calls.run())
        #expect(await probe.useContext("nope", among: config) == false)
        #expect(await probe.useContext("--kubeconfig=/x", among: config) == false)
        #expect(calls.all.isEmpty)
    }

    private let viewArgs = ["kubectl", "config", "view", "-o", "json"]
    private let view = #"{"current-context":"prod","contexts":[{"name":"colima"},{"name":"prod"}]}"#

    @Test func setNamespaceReadsAgainAndNamesTheContextAndNotCurrent() async {
        let calls = Recorder()
        let probe = KubectlProbe(run: calls.run(out: [viewArgs: view]))
        #expect(await probe.setNamespace("shop", context: "prod") == .done)
        #expect(calls.all == [viewArgs, ["kubectl", "config", "set-context", "prod", "--namespace=shop"]])
    }

    @Test func setNamespaceRefusesABadNamespaceOrContext() async {
        let calls = Recorder()
        let probe = KubectlProbe(run: calls.run(out: [viewArgs: view]))
        #expect(await probe.setNamespace("Bad Name", context: "prod") == .failed)
        #expect(await probe.setNamespace("x", context: "nope") == .failed)
        #expect(await probe.setNamespace("x", context: "--current") == .failed)
        #expect(calls.all.filter { $0.contains("set-context") }.isEmpty)
    }

    @Test func setNamespaceNeverMakesAContextThatWentAway() async {
        let calls = Recorder()
        let gone = #"{"current-context":"colima","contexts":[{"name":"colima"}]}"#
        #expect(
            await KubectlProbe(run: calls.run(out: [viewArgs: gone])).setNamespace("shop", context: "prod") == .failed)
        #expect(calls.all == [viewArgs])
    }

    @Test func setNamespaceWritesNothingWhenAnotherContextIsCurrentNow() async {
        let calls = Recorder()
        let other = #"{"current-context":"colima","contexts":[{"name":"colima"},{"name":"prod"}]}"#
        let probe = KubectlProbe(run: calls.run(out: [viewArgs: other]))
        #expect(await probe.setNamespace("shop", context: "prod") == .contextChanged)
        #expect(calls.all == [viewArgs])
    }

    @Test func setNamespaceWritesNothingWhenTheKubeconfigCannotBeRead() async {
        let calls = Recorder()
        #expect(await KubectlProbe(run: calls.run(status: 1)).setNamespace("shop", context: "prod") == .failed)
        #expect(calls.all == [viewArgs])
    }

    @Test func namespacesAskOnlyTheClusterOfARunningColimaProfile() async {
        let calls = Recorder()
        let args = ["kubectl", "--context", "colima", "get", "namespaces", "-o", "name", "--request-timeout=3s"]
        let probe = KubectlProbe(run: calls.run(out: [args: "namespace/default\nnamespace/shop\n"]))
        #expect(await probe.namespaces(context: "colima", runningProfiles: ["default"]) == ["default", "shop"])
        #expect(calls.all == [args])
    }

    @Test func anotherClusterOrAStoppedVMNeverReachesTheRunner() async {
        let calls = Recorder()
        let probe = KubectlProbe(run: calls.run())
        #expect(await probe.namespaces(context: "prod", runningProfiles: ["default", "prod"]) == nil)
        #expect(await probe.namespaces(context: "colima", runningProfiles: []) == nil)
        #expect(calls.all.isEmpty)
    }

    @Test func aFailedListGivesNil() async {
        let probe = KubectlProbe(run: Recorder().run(status: 1))
        #expect(await probe.namespaces(context: "colima", runningProfiles: ["default"]) == nil)
    }
}
