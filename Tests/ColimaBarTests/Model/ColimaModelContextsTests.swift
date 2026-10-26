import Foundation
import Testing

@testable import ColimaBar

/// The context switchers of the model, with a fake runner and a temporary
/// docker config folder. No test runs docker or kubectl.
@MainActor @Suite struct ColimaModelContextsTests {
    @MainActor private final class Rig {
        let folder: TempFolder
        let calls = Recorder()
        let model: ColimaModel
        var notices: [String] = []

        init(readOnly: Bool = false, status: Int32 = 0, out: [[String]: String] = [:]) throws {
            folder = try TempFolder()
            model = ColimaModel(profile: "ctx-\(UUID().uuidString.prefix(6))", readOnly: readOnly)
            model.dockerConfigDir = folder.path
            model.contextRunner = calls.run(status: status, out: out)
            model.kubectlLocator = { "/opt/homebrew/bin/kubectl" }
            model.notifySink = { [weak self] in self?.notices.append($0) }
        }

        func context(_ name: String) throws {
            let dir = "\(folder.path)/contexts/meta/\(name)"
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try Data(#"{"Name":"\#(name)"}"#.utf8).write(to: URL(fileURLWithPath: "\(dir)/meta.json"))
        }

        func current(_ name: String) throws {
            try Data(#"{"currentContext":"\#(name)"}"#.utf8).write(
                to: URL(fileURLWithPath: "\(folder.path)/config.json"))
        }
    }

    private let kubeView = #"""
        {"current-context":"colima","contexts":[
          {"name":"colima","context":{"cluster":"colima","namespace":"shop"}},
          {"name":"prod","context":{"cluster":"prod"}}]}
        """#
    private let viewArgs = ["kubectl", "config", "view", "-o", "json"]

    // MARK: - docker

    @Test func refreshReadsTheContextsAndTheCurrentOne() throws {
        let rig = try Rig()
        try rig.context("colimabar")
        try rig.context("remote")
        try rig.current("remote")
        rig.model.refreshDockerContexts()
        #expect(rig.model.dockerContexts.map(\.name) == ["colimabar", "default", "remote"])
        #expect(rig.model.dockerContextCurrent == "remote")
        #expect(rig.calls.all.isEmpty)
    }

    @Test func pickingAForeignContextKeepsTheChoice() async throws {
        let rig = try Rig()
        try rig.context("remote")
        rig.model.refreshDockerContexts()
        #expect(await rig.model.switchDockerContext(to: "remote"))
        #expect(rig.calls.all == [["docker", "context", "use", "remote"]])
        #expect(rig.model.dockerContextChoice == "remote")
    }

    @Test func pickingDefaultKeepsTheChoice() async throws {
        let rig = try Rig()
        rig.model.refreshDockerContexts()
        #expect(await rig.model.switchDockerContext(to: "default"))
        #expect(rig.model.dockerContextChoice == "default")
    }

    @Test func pickingAColimaBarContextRemovesTheChoice() async throws {
        let rig = try Rig()
        try rig.context("remote")
        try rig.context("colimabar")
        rig.model.refreshDockerContexts()
        await rig.model.switchDockerContext(to: "remote")
        try rig.current("remote")
        #expect(await rig.model.switchDockerContext(to: "colimabar"))
        #expect(rig.model.dockerContextChoice == nil)
    }

    @Test func pickingAColimaContextRemovesTheChoice() async throws {
        let rig = try Rig()
        try rig.context("remote")
        try rig.context("colima")
        rig.model.refreshDockerContexts()
        await rig.model.switchDockerContext(to: "remote")
        #expect(await rig.model.switchDockerContext(to: "colima"))
        #expect(rig.model.dockerContextChoice == nil)
    }

    @Test func aFailedSwitchChangesNothingAndTellsTheUser() async throws {
        let rig = try Rig(status: 1)
        try rig.context("remote")
        rig.model.refreshDockerContexts()
        #expect(await rig.model.switchDockerContext(to: "remote") == false)
        #expect(rig.model.dockerContextChoice == nil)
        #expect(rig.notices == ["ColimaBar could not switch the docker context to remote. See the log."])
    }

    @Test func aNameThatDoesNotExistNeverReachesDocker() async throws {
        let rig = try Rig()
        rig.model.refreshDockerContexts()
        #expect(await rig.model.switchDockerContext(to: "-x") == false)
        #expect(await rig.model.switchDockerContext(to: "gone") == false)
        #expect(rig.calls.all.isEmpty)
    }

    @Test func switchingBackToAColimaBarContextInATerminalDropsTheChoice() async throws {
        let rig = try Rig()
        try rig.context("remote")
        try rig.context("colimabar")
        rig.model.refreshDockerContexts()
        await rig.model.switchDockerContext(to: "remote")
        try rig.current("colimabar")
        rig.model.refreshDockerContexts()
        #expect(rig.model.dockerContextChoice == nil)
    }

    @Test func aChoiceStaysWhileColimaHasJustSwitchedTheContext() async throws {
        let rig = try Rig()
        try rig.context("remote")
        rig.model.refreshDockerContexts()
        await rig.model.switchDockerContext(to: "remote")
        try rig.current("colima-work")
        rig.model.refreshDockerContexts()
        #expect(rig.model.dockerContextChoice == "remote")
    }

    @Test func aChoiceThatNoLongerExistsIsDropped() async throws {
        let rig = try Rig()
        try rig.context("remote")
        rig.model.refreshDockerContexts()
        await rig.model.switchDockerContext(to: "remote")
        try FileManager.default.removeItem(atPath: "\(rig.folder.path)/contexts")
        rig.model.refreshDockerContexts()
        #expect(rig.model.dockerContextChoice == nil)
    }

    @Test func aDebugRunSwitchesNothing() async throws {
        let rig = try Rig(readOnly: true)
        try rig.context("remote")
        rig.model.refreshDockerContexts()
        #expect(await rig.model.switchDockerContext(to: "remote") == false)
        #expect(rig.model.dockerContextChoice == nil)
        #expect(rig.calls.all.isEmpty)
    }

    // MARK: - kubectl

    @Test func nothingRunsWhileTheSettingIsOff() async throws {
        let rig = try Rig(out: [viewArgs: kubeView])
        await rig.model.refreshKube()
        #expect(rig.calls.all.isEmpty)
        #expect(rig.model.kubectlAvailable)
        #expect(!rig.model.showsKubectl)
        #expect(rig.model.kubeConfig == nil)
    }

    @Test func nothingShowsWhenKubectlIsMissing() async throws {
        let rig = try Rig(out: [viewArgs: kubeView])
        rig.model.kubectlLocator = { nil }
        rig.model.kubectlSwitcher = true
        await rig.model.refreshKube()
        #expect(!rig.model.showsKubectl)
        #expect(rig.calls.all.isEmpty)
    }

    @Test func theSettingShowsTheKubeconfig() async throws {
        let rig = try Rig(out: [viewArgs: kubeView])
        rig.model.kubectlSwitcher = true
        await rig.model.refreshKube()
        #expect(rig.model.showsKubectl)
        #expect(rig.model.kubeConfig?.current == "colima")
        #expect(rig.model.kubeNamespaceEntries.map(\.name) == ["default", "shop"])
    }

    @Test func anUnreadableKubeconfigShowsNoContexts() async throws {
        let rig = try Rig(status: 1)
        rig.model.kubectlSwitcher = true
        await rig.model.refreshKube()
        #expect(rig.model.showsKubectl)
        #expect(rig.model.kubeConfig == nil)
        #expect(rig.model.kubeContextEntries.isEmpty)
        #expect(rig.model.kubeReadFailed)
    }

    @Test func aReadThatHasNotRunYetIsNotAFailure() throws {
        let rig = try Rig(out: [viewArgs: kubeView])
        rig.model.kubectlSwitcher = true
        #expect(rig.model.kubeConfig == nil)
        #expect(rig.model.kubeReadFailed == false)
    }

    @Test func aNamespaceNeverMakesAContextThatWentAway() async throws {
        let rig = try Rig(out: [viewArgs: kubeView])
        rig.model.kubectlSwitcher = true
        await rig.model.refreshKube()
        let after = Recorder()
        let gone = #"{"current-context":"prod","contexts":[{"name":"prod","context":{}}]}"#
        rig.model.contextRunner = after.run(out: [viewArgs: gone])
        #expect(await rig.model.setKubeNamespace("blog") == false)
        #expect(after.all == [viewArgs])
    }

    @Test func switchingTheKubeContextRunsUseContextAndReadsAgain() async throws {
        let rig = try Rig(out: [viewArgs: kubeView])
        rig.model.kubectlSwitcher = true
        await rig.model.refreshKube()
        #expect(await rig.model.switchKubeContext(to: "prod"))
        #expect(rig.calls.all.contains(["kubectl", "config", "use-context", "prod"]))
        #expect(rig.calls.all.last == viewArgs)
    }

    @Test func aNamespaceGoesToTheCurrentContextByName() async throws {
        let rig = try Rig(out: [viewArgs: kubeView])
        rig.model.kubectlSwitcher = true
        await rig.model.refreshKube()
        #expect(await rig.model.setKubeNamespace("blog"))
        #expect(rig.calls.all.contains(["kubectl", "config", "set-context", "colima", "--namespace=blog"]))
    }

    @Test func aBadNamespaceNeverReachesKubectlAndTellsTheUser() async throws {
        let rig = try Rig(out: [viewArgs: kubeView])
        rig.model.kubectlSwitcher = true
        await rig.model.refreshKube()
        #expect(await rig.model.setKubeNamespace("Bad Name") == false)
        #expect(rig.calls.all == [viewArgs])
        #expect(rig.notices == ["ColimaBar could not set the namespace of colima to Bad Name. See the log."])
    }

    @Test func namespacesComeFromARunningColimaClusterAtMostOnceInTheGap() async throws {
        let list = ["kubectl", "--context", "colima", "get", "namespaces", "-o", "name", "--request-timeout=3s"]
        let rig = try Rig(out: [viewArgs: kubeView, list: "namespace/default\nnamespace/blog\n"])
        rig.model.kubectlSwitcher = true
        await rig.model.refreshKube()
        await rig.model.refreshKubeNamespaces(running: ["default"])
        await rig.model.refreshKubeNamespaces(running: ["default"])
        #expect(rig.calls.all.filter { $0 == list }.count == 1)
        #expect(rig.model.kubeNamespaceEntries.map(\.name) == ["blog", "default", "shop"])
    }

    @Test func aStoppedVMListsNoNamespaces() async throws {
        let rig = try Rig(out: [viewArgs: kubeView])
        rig.model.kubectlSwitcher = true
        await rig.model.refreshKube()
        await rig.model.refreshKubeNamespaces(running: [])
        #expect(rig.calls.all == [viewArgs])
    }

    @Test func anotherClusterListsNoNamespaces() async throws {
        let other = kubeView.replacingOccurrences(
            of: #""current-context":"colima""#, with: #""current-context":"prod""#)
        let rig = try Rig(out: [viewArgs: other])
        rig.model.kubectlSwitcher = true
        await rig.model.refreshKube()
        await rig.model.refreshKubeNamespaces(running: ["default", "prod"])
        #expect(rig.calls.all == [viewArgs])
    }

    @Test func aDebugRunSwitchesNothingInKubectl() async throws {
        let rig = try Rig(readOnly: true, out: [viewArgs: kubeView])
        rig.model.kubectlSwitcher = true
        await rig.model.refreshKube()
        #expect(await rig.model.switchKubeContext(to: "prod") == false)
        #expect(await rig.model.setKubeNamespace("blog") == false)
        await rig.model.refreshKubeNamespaces(running: ["default"])
        #expect(rig.calls.all == [viewArgs])
    }

    // MARK: - fixture

    private let fixture = #"""
        {"docker":{"current":"remote","contexts":[{"name":"colimabar"},{"name":"remote","description":"Box"}]},
         "kube":{"current":"colima","contexts":[{"name":"colima","namespace":"shop"}],
                 "namespaces":{"colima":["default","shop"]}}}
        """#

    @Test func aDebugRunShowsTheFixtureAndKeepsIt() async throws {
        let rig = try Rig(readOnly: true)
        #expect(rig.model.loadContextsFixture(Data(fixture.utf8)))
        rig.model.refreshDockerContexts()
        await rig.model.refreshKube()
        #expect(rig.model.dockerContexts.map(\.name) == ["colimabar", "remote"])
        #expect(rig.model.dockerContextCurrent == "remote")
        #expect(rig.model.showsKubectl)
        #expect(rig.model.kubeNamespaceEntries.map(\.name) == ["default", "shop"])
        #expect(rig.calls.all.isEmpty)
    }

    @Test func aNormalRunIgnoresTheFixture() throws {
        let rig = try Rig()
        #expect(rig.model.loadContextsFixture(Data(fixture.utf8)) == false)
        #expect(rig.model.dockerContexts.isEmpty)
    }

    @Test func aFileThatIsNotAFixtureIsRefused() throws {
        let rig = try Rig(readOnly: true)
        #expect(rig.model.loadContextsFixture(Data("nope".utf8)) == false)
    }
}
