import Foundation
import Testing

@testable import ColimaBar

@Suite struct RoutingTests {
    @Test func matchesEqualsWithoutSpaces() {
        #expect(Routing.dockerHostValue("docker.host=unix:///tmp/a.sock") == "unix:///tmp/a.sock")
    }

    @Test func matchesEqualsWithSpaces() {
        #expect(Routing.dockerHostValue("docker.host = tcp://remote:2375") == "tcp://remote:2375")
    }

    @Test func matchesColonSeparator() {
        #expect(Routing.dockerHostValue("docker.host:tcp://remote:2375") == "tcp://remote:2375")
        #expect(Routing.dockerHostValue("docker.host : tcp://remote:2375") == "tcp://remote:2375")
    }

    @Test func matchesLeadingWhitespace() {
        #expect(Routing.dockerHostValue("   docker.host=tcp://remote:2375") == "tcp://remote:2375")
        #expect(Routing.dockerHostValue("\tdocker.host=tcp://remote:2375  ") == "tcp://remote:2375")
    }

    @Test func ignoresCommentsAndOtherKeys() {
        #expect(Routing.dockerHostValue("#docker.host=tcp://remote:2375") == nil)
        #expect(Routing.dockerHostValue("  # docker.host=tcp://remote:2375") == nil)
        #expect(Routing.dockerHostValue("docker.hostname=foo") == nil)
        #expect(Routing.dockerHostValue("ryuk.disabled=true") == nil)
        #expect(Routing.dockerHostValue("docker.host") == nil)
    }

    @Test func whitespaceAloneSeparatesKeyAndValue() {
        #expect(Routing.dockerHostValue("docker.host tcp://remote:2375") == "tcp://remote:2375")
        #expect(Routing.dockerHostValue("docker.host\ttcp://remote:2375") == "tcp://remote:2375")
        #expect(Routing.dockerHostValue("  docker.host   unix:///tmp/a.sock\r") == "unix:///tmp/a.sock")
    }

    @Test func whitespaceThenSeparatorStillWorks() {
        #expect(Routing.dockerHostValue("docker.host   =  tcp://remote:2375") == "tcp://remote:2375")
        #expect(Routing.dockerHostValue("docker.host  :tcp://remote:2375") == "tcp://remote:2375")
    }

    @Test func otherKeysDoNotMatch() {
        #expect(Routing.dockerHostValue("docker.hostname tcp://remote:2375") == nil)
        #expect(Routing.dockerHostValue("docker.hostname=foo") == nil)
        #expect(Routing.dockerHostValue("docker.host") == nil)
        #expect(Routing.dockerHostValue("# docker.host tcp://remote:2375") == nil)
    }

    // MARK: - docker context

    private func target(_ current: String, _ existing: Set<String>, selected: String = "default", launch: Bool = false)
        -> String?
    {
        Routing.contextTarget(current: current, existing: existing, selected: selected, launch: launch)
    }

    @Test func colimabarContextStays() {
        #expect(target("colimabar", ["colimabar", "colima"], launch: true) == nil)
    }

    @Test func defaultContextMovesOnlyAtLaunch() {
        #expect(target("", ["colimabar"], launch: true) == "colimabar")
        #expect(target("default", ["colimabar"], launch: true) == "colimabar")
        #expect(target("", ["colimabar"]) == nil)
        #expect(target("default", ["colimabar"]) == nil)
    }

    @Test func colimaContextOfSelectedProfileMovesToColimabar() {
        #expect(target("colima", ["colimabar", "colima"]) == "colimabar")
        #expect(target("colima-work", ["colimabar", "colima-work"], selected: "work") == "colimabar")
    }

    @Test func missingColimaContextMovesToColimabar() {
        #expect(target("colima", ["colimabar"]) == "colimabar")
        #expect(target("colima-work", ["colimabar"]) == "colimabar")
    }

    @Test func colimaContextOfOtherProfileMovesToItsColimabarContext() {
        #expect(target("colima-work", ["colimabar", "colimabar-work", "colima-work"]) == "colimabar-work")
        #expect(target("colima", ["colimabar", "colimabar-default"], selected: "work") == "colimabar-default")
    }

    @Test func existingColimaContextOfOtherProfileStaysWithoutColimabarContext() {
        #expect(target("colima-work", ["colimabar", "colima-work"]) == nil)
    }

    @Test func colimabarProfileContextIsNotTreatedAsColimaContext() {
        #expect(target("colimabar-work", ["colimabar", "colimabar-work"]) == nil)
        #expect(target("colimabar-work", ["colimabar"]) == "colimabar")
    }

    @Test func otherContextStaysIfItExistsAndMovesIfItIsMissing() {
        #expect(target("remote", ["colimabar", "remote"], launch: true) == nil)
        #expect(target("remote", ["colimabar"], launch: true) == "colimabar")
        #expect(target("remote", ["colimabar"]) == "colimabar")
    }

    @Test func colimaProfileInvertsKubeContext() {
        #expect(Routing.colimaProfile("colima") == "default")
        #expect(Routing.colimaProfile("colima-work") == "work")
        #expect(Routing.colimaProfile(Paths.kubeContext("a-b")) == "a-b")
        #expect(Routing.colimaProfile("colima-") == nil)
        #expect(Routing.colimaProfile("colimabar") == nil)
        #expect(Routing.colimaProfile("colimabar-work") == nil)
        #expect(Routing.colimaProfile("default") == nil)
    }

    @Test func currentContextComesFromConfig() {
        func read(_ json: String) -> String? { Routing.currentContext(config: Data(json.utf8)) }
        #expect(read(#"{"auths":{},"currentContext":"colima"}"#) == "colima")
        #expect(read(#"{"auths":{}}"#) == "")
        #expect(read("not json") == nil)
        #expect(read("[]") == nil)
        #expect(read("") == "")
        #expect(read(" \n") == "")
    }

    @Test func currentContextFromFileReadsMissingAsDefaultAndDirectoryAsUnreadable() throws {
        let dir = NSTemporaryDirectory() + "routing-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        #expect(Routing.currentContext(path: "\(dir)/missing.json") == "")
        #expect(Routing.currentContext(path: dir) == nil)
        let file = "\(dir)/config.json"
        try Data(#"{"currentContext":"colima"}"#.utf8).write(to: URL(fileURLWithPath: file))
        #expect(Routing.currentContext(path: file) == "colima")
        let link = "\(dir)/link.json"
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: file)
        #expect(Routing.currentContext(path: link) == "colima")
    }

    @Test func existingContextsSkipsTheErrorRowOfAMissingCurrentContext() {
        let listing = "colimabar\t\ndefault\t\ncolima-work\tcontext not found: context \"colima-work\" does not exist\n"
        #expect(Routing.existingContexts(listing: listing) == ["colimabar", "default"])
        #expect(Routing.existingContexts(listing: "") == [])
    }

    @Test func missingCurrentContextMovesToColimabarWhenListedWithAnError() {
        let existing = Routing.existingContexts(listing: "colimabar\t\ncolima-work\tcontext not found\n")
        #expect(target("colima-work", existing, selected: "work") == "colimabar")
    }

    @Test func colimabarProfileContextsAreOurs() {
        #expect(Routing.isOurs("colimabar"))
        #expect(Routing.isOurs("colimabar-work"))
        #expect(!Routing.isOurs("colima"))
        #expect(!Routing.isOurs(""))
    }

    @Test func contextCheckRunsOnAConfigChangeOrWhenARetryIsDue() {
        let t = Date(timeIntervalSince1970: 1_000_000)
        let later = t.addingTimeInterval(120)
        #expect(!ColimaModel.contextCheckDue(stamp: t, lastStamp: t, retryAt: nil, now: later))
        #expect(ColimaModel.contextCheckDue(stamp: later, lastStamp: t, retryAt: nil, now: later))
        #expect(!ColimaModel.contextCheckDue(stamp: t, lastStamp: t, retryAt: later, now: t))
        #expect(ColimaModel.contextCheckDue(stamp: t, lastStamp: t, retryAt: t, now: later))
    }

    @Test func failedContextChecksRetryOnlyAFewTimes() {
        let t = Date(timeIntervalSince1970: 1000)
        #expect(ColimaModel.contextCheckRetryAt(failures: 1, now: t) == t.addingTimeInterval(60))
        #expect(ColimaModel.contextCheckRetryAt(failures: ColimaModel.contextCheckMaxRetries, now: t) != nil)
        #expect(ColimaModel.contextCheckRetryAt(failures: ColimaModel.contextCheckMaxRetries + 1, now: t) == nil)
    }

    @Test func configStampFollowsTheFile() throws {
        let dir = NSTemporaryDirectory() + "routing-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let file = "\(dir)/config.json"
        try Data("{}".utf8).write(to: URL(fileURLWithPath: file))
        let old = Date(timeIntervalSince1970: 1_000_000)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: file)
        let stamp = (try FileManager.default.attributesOfItem(atPath: file))[.modificationDate] as? Date
        #expect(stamp == old)
        #expect(Routing.configStamp(path: file) == old)
        #expect(Routing.configStamp(path: "\(dir)/missing.json") == nil)
    }

    @Test func configStampFollowsASymlinkToTheTarget() throws {
        let dir = NSTemporaryDirectory() + "routing-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let target = "\(dir)/real.json"
        let link = "\(dir)/config.json"
        try Data("{}".utf8).write(to: URL(fileURLWithPath: target))
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: target)
        let old = Date(timeIntervalSince1970: 2_000_000)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: target)
        #expect(Routing.configStamp(path: link) == old)
    }

    @Test func onlyAHostOfAnotherDaemonIsForeign() {
        let stable = "unix:///Users/me/.cache/colima-bar/docker.sock"
        func foreign(_ h: String?) -> Bool { Routing.isForeignHost(h, stableHost: stable, home: "/Users/me") }
        #expect(!foreign(nil) && !foreign("") && !foreign(stable))
        // Both Colima folders are Colima's, not another daemon.
        #expect(!foreign("unix:///Users/me/.colima/default/docker.sock"))
        #expect(!foreign("unix:///Users/me/.config/colima/default/docker.sock"))
        #expect(foreign("tcp://remote:2375"))
        #expect(foreign("ssh://me@host/home/me/.colima/default/docker.sock"))
        #expect(foreign("unix:///Users/me/.docker/run/docker.sock"))
    }

    @MainActor @Test func firstWriteCreatesTheTestcontainersFile() throws {
        let dir = try TempFolder()
        let path = dir.path + "/tc.properties"
        #expect(Routing.applyTestcontainers(path: path))
        #expect(try String(contentsOfFile: path, encoding: .utf8) == "docker.host=\(Routing.stableHost)\n")
    }

    @MainActor @Test func testcontainersFileThatCannotBeReadIsLeftAlone() throws {
        let dir = try TempFolder()
        let path = dir.path + "/tc.properties"
        let bytes = Data([0x61, 0x3D, 0xFF, 0x0A])
        try bytes.write(to: URL(fileURLWithPath: path))
        #expect(!Routing.applyTestcontainers(path: path))
        #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == bytes)
        try "docker.host=tcp://remote:2375\n".write(toFile: path, atomically: true, encoding: .utf8)
        #expect(!Routing.applyTestcontainers(path: path))
    }
}
