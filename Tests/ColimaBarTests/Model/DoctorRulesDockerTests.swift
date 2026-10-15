import Foundation
import Testing

@testable import ColimaBar

@Suite struct DoctorRulesDockerTests {
    private let home = DoctorFixture.home
    private func result(_ check: DoctorCheck, _ i: DoctorInputs) throws -> DoctorResult {
        try #require(DoctorRules.evaluate(i).first { $0.check == check })
    }

    // MARK: context

    private func ctx(_ current: String?, existing: Set<String>? = ["default", "colimabar"]) -> DoctorInputs {
        var i = DoctorFixture.healthy()
        i.context = .init(current: current, existing: existing)
        return i
    }

    @Test func aColimaBarContextIsOk() throws {
        #expect(try result(.context, ctx("colimabar")).status == .ok)
        #expect(try result(.context, ctx("colimabar-work", existing: ["colimabar-work"])).status == .ok)
    }

    @Test func aMissingCurrentContextIsAProblemWithAFix() throws {
        let r = try result(.context, ctx("colima"))
        #expect(r.status == .problem && r.fix == .useColimabar && r.detail.contains("context not found"))
        #expect(try result(.context, ctx("colimabar-gone")).status == .problem)
    }

    @Test func theDefaultAndColimaContextsAreAWarningWithAFix() throws {
        for current in ["", "default"] {
            let r = try result(.context, ctx(current))
            #expect(r.status == .warning && r.fix == .useColimabar)
        }
        let colima = try result(.context, ctx("colima-work", existing: ["colima-work"]))
        #expect(colima.status == .warning && colima.fix == .useColimabar)
    }

    @Test func anotherWorkingContextIsAWarningWithNoFix() throws {
        let r = try result(.context, ctx("remote", existing: ["remote"]))
        #expect(r.status == .warning && r.fix == nil)
    }

    @Test func theContextIsSkippedWhenAutoStartIsOff() throws {
        var i = ctx("default")
        i.autoStart = false
        #expect(try result(.context, i).status == .skipped)
    }

    @Test func anUnreadableConfigOrADeadDockerCLIIsAWarning() throws {
        #expect(try result(.context, ctx(nil)).status == .warning)
        #expect(try result(.context, ctx("colimabar", existing: nil)).status == .warning)
    }

    // MARK: shellHost

    private func shell(_ value: String?, file: String = "/Users/me/.zshrc") -> DoctorInputs {
        var i = DoctorFixture.healthy()
        i.shell = .init(name: "zsh", found: .init(file: file, line: 12, value: value))
        return i
    }

    @Test func hostKindsFollowThePathOfTheSocket() {
        let kind = { DoctorRules.hostKind($0, home: DoctorFixture.home) }
        #expect(kind("unix:///Users/me/.cache/colima-bar/docker.sock") == .colimaBar)
        #expect(kind("unix://$HOME/.cache/colima-bar/docker.sock") == .colimaBar)
        #expect(kind("unix://~/.colima/default/docker.sock") == .colima)
        #expect(kind("unix:///Users/me/.colima/work/docker.sock") == .colima)
        #expect(kind("unix:///Users/me/.docker/run/docker.sock") == .dockerDesktop)
        #expect(kind("unix:///Users/me/Library/Containers/com.docker.docker/Data/docker.raw.sock") == .dockerDesktop)
        #expect(kind("tcp://remote:2375") == .other)
        #expect(kind("ssh://me@host") == .other)
    }

    @Test func noAssignmentOrARemovalIsOk() throws {
        #expect(try result(.shellHost, DoctorFixture.healthy()).status == .ok)
        #expect(try result(.shellHost, shell(nil)).status == .ok)
    }

    @Test func theShellSocketDecidesTheStatusAndTheFix() throws {
        let ours = try result(.shellHost, shell("unix:///Users/me/.cache/colima-bar/docker.sock"))
        #expect(ours.status == .ok)
        let colima = try result(.shellHost, shell("unix:///Users/me/.colima/default/docker.sock"))
        #expect(colima.status == .warning && colima.fix == .copyLine)
        #expect(colima.detail.contains("~/.zshrc line 12"))
        let desktop = try result(.shellHost, shell("unix:///Users/me/.docker/run/docker.sock"))
        #expect(desktop.status == .problem && desktop.fix == .copyLine)
        let remote = try result(.shellHost, shell("tcp://remote:2375"))
        #expect(remote.status == .warning && remote.fix == nil)
    }

    // MARK: credentials

    private func creds(_ config: DockerConfig?, available: Set<String>) -> DoctorInputs {
        var i = DoctorFixture.healthy()
        i.credentials = .init(config: config, available: available)
        return i
    }

    @Test func aMissingCredsStoreHelperIsAProblem() throws {
        let c = DockerConfig(credsStore: "desktop")
        let withKeychain = try result(.credentials, creds(c, available: ["osxkeychain"]))
        #expect(withKeychain.status == .problem && withKeychain.fix == .useOsxkeychain)
        let without = try result(.credentials, creds(c, available: []))
        #expect(without.status == .problem && without.fix == nil)
    }

    @Test func aMissingCredHelperIsAWarningWithNoFix() throws {
        let c = DockerConfig(credHelpers: ["gcr.io": "gcloud"])
        let r = try result(.credentials, creds(c, available: ["osxkeychain"]))
        #expect(r.status == .warning && r.fix == nil && r.detail.contains("gcr.io"))
    }

    @Test func aWorkingHelperOrNoHelperIsOk() throws {
        #expect(
            try result(.credentials, creds(DockerConfig(credsStore: "osxkeychain"), available: ["osxkeychain"])).status
                == .ok)
        #expect(try result(.credentials, creds(DockerConfig(), available: [])).status == .ok)
    }

    @Test func aConfigThatIsNotJSONIsAWarning() throws {
        #expect(try result(.credentials, creds(nil, available: [])).status == .warning)
    }

    // MARK: plugins

    private typealias Entry = DoctorInputs.PluginEntry
    private func plugins(_ entries: [Entry], names: [String] = ["docker-buildx", "docker-compose"]) -> DoctorInputs {
        var i = DoctorFixture.healthy()
        i.plugins = names.map { .init(name: $0, entries: entries) }
        return i
    }
    private let brew = DoctorRules.homebrewPluginFolder

    @Test func theFirstFolderWithTheFileDecides() throws {
        let broken = Entry(folder: "/a", state: .broken, searchedByDocker: true)
        let works = Entry(folder: "/b", state: .works, searchedByDocker: true)
        let r = try result(.plugins, plugins([broken, works]))
        #expect(r.status == .problem && r.detail.contains("rm '/a/docker-buildx'"))
        #expect(try result(.plugins, plugins([works, broken])).status == .ok)
    }

    @Test func aPluginOnlyInTheHomebrewFolderIsAWarningWithAFix() throws {
        let missing = Entry(folder: "/a", state: .missing, searchedByDocker: true)
        let homebrew = Entry(folder: brew, state: .works, searchedByDocker: false)
        let r = try result(.plugins, plugins([missing, homebrew]))
        #expect(r.status == .warning && r.fix == .addPluginFolder)
        // docker searches the folder once cliPluginsExtraDirs names it.
        let searched = Entry(folder: brew, state: .works, searchedByDocker: true)
        #expect(try result(.plugins, plugins([searched])).status == .ok)
    }

    @Test func theSuggestedRmUsesTheAbsolutePathBecauseQuotesStopTheTildeExpansion() throws {
        let broken = Entry(folder: "\(home)/.docker/cli-plugins", state: .broken, searchedByDocker: true)
        let r = try result(.plugins, plugins([broken], names: ["docker-buildx"]))
        #expect(r.detail.contains("rm '\(home)/.docker/cli-plugins/docker-buildx'"))
        #expect(!r.detail.contains("rm '~"))
        #expect(DoctorRules.shellQuoted("/a/it's") == #"'/a/it'\''s'"#)
    }

    @Test func theGrammarFollowsTheNumberOfPluginsInTheHomebrewFolderOnly() throws {
        let missing = Entry(folder: "/a", state: .missing, searchedByDocker: true)
        let homebrew = Entry(folder: brew, state: .works, searchedByDocker: false)
        #expect(
            try result(.plugins, plugins([missing, homebrew])).detail.contains(
                "docker-buildx and docker-compose are only in"))
        #expect(
            try result(.plugins, plugins([missing, homebrew], names: ["docker-buildx"])).detail.contains(
                "docker-buildx is only in"))
    }

    @Test func aBrokenPluginBesideAHomebrewOnlyOneIsAProblemWithTheFolderFix() throws {
        let broken = Entry(folder: "/a", state: .broken, searchedByDocker: true)
        let missing = Entry(folder: "/a", state: .missing, searchedByDocker: true)
        let homebrew = Entry(folder: brew, state: .works, searchedByDocker: false)
        var i = DoctorFixture.healthy()
        i.plugins = [
            .init(name: "docker-buildx", entries: [broken]),
            .init(name: "docker-compose", entries: [missing, homebrew]),
        ]
        let r = try result(.plugins, i)
        #expect(r.status == .problem && r.fix == .addPluginFolder)
        #expect(r.detail.contains("rm '/a/docker-buildx'") && r.detail.contains("docker-compose is only in"))
    }

    @Test func anUnreadableDockerConfigIsAWarningWithNoConfigFix() throws {
        var i = DoctorFixture.healthy()
        i.dockerConfigUnreadable = true
        let c = try result(.credentials, i)
        #expect(c.status == .warning && c.fix == nil && c.detail.contains("cannot read"))
        let missing = Entry(folder: "/a", state: .missing, searchedByDocker: true)
        let homebrew = Entry(folder: brew, state: .works, searchedByDocker: false)
        i.plugins = [.init(name: "docker-buildx", entries: [missing, homebrew])]
        let p = try result(.plugins, i)
        #expect(p.status == .warning && p.fix == nil && p.detail.contains("cannot read the docker config file"))
    }

    @Test func aStartupFileThatCannotBeReadLowersTheShellResultToAWarning() throws {
        var i = shell(nil)
        i.shell.unreadable = ["/Users/me/.zshrc"]
        let r = try result(.shellHost, i)
        #expect(r.status == .warning && r.detail.contains("could not read ~/.zshrc"))
        // A problem stays a problem.
        var bad = shell("unix:///Users/me/.docker/run/docker.sock")
        bad.shell.unreadable = ["/Users/me/.zprofile"]
        #expect(try result(.shellHost, bad).status == .problem)
    }

    @Test func aMissingPluginIsAWarningThatNamesBrew() throws {
        let missing = Entry(folder: "/a", state: .missing, searchedByDocker: true)
        let r = try result(.plugins, plugins([missing]))
        #expect(r.status == .warning && r.fix == nil)
        #expect(r.detail.contains("brew install docker-buildx docker-compose"))
    }
}
