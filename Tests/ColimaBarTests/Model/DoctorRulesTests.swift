import Foundation
import Testing

@testable import ColimaBar

@Suite struct DoctorRulesTests {
    private let home = DoctorFixture.home
    private func result(_ check: DoctorCheck, _ i: DoctorInputs) throws -> DoctorResult {
        try #require(DoctorRules.evaluate(i).first { $0.check == check })
    }

    @Test func aHealthySetupHasNoFinding() {
        let results = DoctorRules.evaluate(DoctorFixture.healthy())
        #expect(results.map(\.check) == DoctorCheck.allCases)
        for r in results { #expect(r.status == .ok, "\(r.check): \(r.detail)") }
        #expect(results.allSatisfy { $0.fix == nil })
    }

    // MARK: tools

    @Test func aMissingColimaOrLimactlIsAProblem() throws {
        var i = DoctorFixture.healthy()
        i.tools.limactlPath = nil
        let r = try result(.tools, i)
        #expect(r.status == .problem && r.detail.contains("limactl"))
        i.tools.colimaPath = nil
        #expect(try result(.tools, i).detail.contains("colima and limactl"))
    }

    @Test func aMissingDockerCLIOrAnOldLimaIsAWarning() throws {
        var i = DoctorFixture.healthy()
        i.tools.dockerPath = nil
        #expect(try result(.tools, i).status == .warning)
        i = DoctorFixture.healthy()
        i.tools.versions.lima = "2.0.3"
        let r = try result(.tools, i)
        #expect(r.status == .warning && r.detail.contains("2.0.3"))
    }

    @Test func theToolsDetailListsTheVersions() throws {
        #expect(try result(.tools, DoctorFixture.healthy()).detail == "colima 0.10.3, lima 2.2.1, docker 29.0.1")
    }

    // MARK: appRoutes

    @Test func routesAreSkippedWhenAutoStartIsOff() throws {
        var i = DoctorFixture.healthy()
        i.autoStart = false
        i.routes = .init()
        #expect(try result(.appRoutes, i).status == .skipped)
    }

    @Test func missingRoutesAreAWarningWithASetRoutesFix() throws {
        var i = DoctorFixture.healthy()
        i.routes = .init(launchdHost: "", testcontainersHost: nil)
        let r = try result(.appRoutes, i)
        #expect(r.status == .warning && r.fix == .setRoutes)
    }

    @Test func aRouteToAnotherDaemonIsAWarningWithNoFix() throws {
        var i = DoctorFixture.healthy()
        i.routes = .init(launchdHost: "tcp://remote:2375", testcontainersHost: DoctorFixture.stableHost)
        let r = try result(.appRoutes, i)
        #expect(r.status == .warning && r.fix == nil && r.detail.contains("tcp://remote:2375"))
    }

    @Test func aColimaRouteCountsAsOursToFixAndAnotherRouteBesideAMissingOneKeepsTheFix() throws {
        var i = DoctorFixture.healthy()
        i.routes = .init(launchdHost: "tcp://remote:2375", testcontainersHost: nil)
        #expect(try result(.appRoutes, i).fix == .setRoutes)
        // The default Colima folder is Colima's, not another daemon.
        i.routes = .init(
            launchdHost: "unix:///Users/me/.colima/default/docker.sock", testcontainersHost: DoctorFixture.stableHost)
        #expect(try result(.appRoutes, i).fix == .setRoutes)
    }

    @Test func aTestcontainersHostOfAnotherDaemonIsAWarningWithNoFix() throws {
        var i = DoctorFixture.healthy()
        i.routes = .init(launchdHost: DoctorFixture.stableHost, testcontainersHost: "tcp://remote:2375")
        let r = try result(.appRoutes, i)
        #expect(r.status == .warning && r.fix == nil && r.detail.contains("testcontainers docker.host points"))
    }

    @Test func setRoutesIsOfferedOnlyWhenTheContextAllowsIt() throws {
        var i = DoctorFixture.healthy()
        i.routes = .init(launchdHost: "", testcontainersHost: nil)
        for current in ["colimabar", "colimabar-work", "", "default", "colima", "colima-work"] {
            i.context = .init(current: current, existing: [current])
            #expect(try result(.appRoutes, i).fix == .setRoutes, "context \(current)")
        }
        // A context that does not exist moves to colimabar.
        i.context = .init(current: "gone", existing: ["colimabar"])
        #expect(try result(.appRoutes, i).fix == .setRoutes)
        // The context of the user stays, so the fix would do nothing.
        i.context = .init(current: "remote", existing: ["remote"])
        let r = try result(.appRoutes, i)
        #expect(r.status == .warning && r.fix == nil && r.detail.contains("not a ColimaBar context"))
        i.context = .init(current: nil, existing: nil)
        #expect(try result(.appRoutes, i).fix == nil)
    }

    // MARK: tools that fail

    @Test func aToolThatExistsButDoesNotRunIsAWarning() throws {
        var i = DoctorFixture.healthy()
        i.tools.versions.lima = nil
        let r = try result(.tools, i)
        #expect(r.status == .warning && r.detail.contains("limactl did not run"))
        i.tools.versions.colima = nil
        #expect(try result(.tools, i).detail.contains("colima and limactl did not run"))
    }

    // MARK: vmStatus

    @Test func aBrokenProfileIsAProblemWithARepairFix() throws {
        var i = DoctorFixture.healthy()
        i.vm = .init(selected: DoctorFixture.row("default", "Broken"), others: [])
        let r = try result(.vmStatus, i)
        #expect(r.status == .problem && r.fix == .repair)
    }

    @Test func runningAndStoppedAreOkAndOtherStatusesAreAWarning() throws {
        var i = DoctorFixture.healthy()
        i.vm = .init(selected: DoctorFixture.row("default", "Stopped"), others: [])
        #expect(try result(.vmStatus, i).status == .ok)
        i.vm = .init(selected: DoctorFixture.row("default", "Starting"), others: [])
        #expect(try result(.vmStatus, i).status == .warning)
        i.vm = .init(selected: nil, others: [])
        #expect(try result(.vmStatus, i).status == .ok)
    }

    @Test func aFailedColimaListIsAWarningNotAnOkForAnEmptyList() throws {
        var i = DoctorFixture.healthy()
        i.vm = .init(selected: nil, others: [], listFailed: true)
        let r = try result(.vmStatus, i)
        #expect(r.status == .warning && r.detail.contains("colima list failed"))
        // Rows from an earlier list do not hide the failure.
        i.vm = .init(selected: DoctorFixture.row("default", "Running"), others: [], listFailed: true)
        #expect(try result(.vmStatus, i).status == .warning)
    }

    @Test func otherBrokenProfilesAreNamed() throws {
        var i = DoctorFixture.healthy()
        i.vm = .init(
            selected: DoctorFixture.row("default", "Running"),
            others: [DoctorFixture.row("default", "Running"), DoctorFixture.row("work", "Broken")])
        let r = try result(.vmStatus, i)
        #expect(r.status == .warning && r.detail.contains("work") && r.fix == nil)
    }

    // MARK: staleFiles

    private func stale(_ reason: StaleLimaFile.Reason, _ name: String = "colima/ha.pid") -> StaleLimaFile {
        StaleLimaFile(reason: reason, path: "\(home)/.colima/_lima/\(name)", pid: "1")
    }

    @Test func aReusedOrInvalidPidFileIsAProblemWithARepairFix() throws {
        var i = DoctorFixture.healthy()
        i.staleFiles = [stale(.reused)]
        let r = try result(.staleFiles, i)
        #expect(r.status == .problem && r.fix == .repair)
        #expect(r.detail.contains("~/.colima/_lima/colima/ha.pid"))
        i.staleFiles = [stale(.invalid)]
        #expect(try result(.staleFiles, i).status == .problem)
    }

    @Test func aGonePidFileIsOkBecauseLimaRemovesIt() throws {
        var i = DoctorFixture.healthy()
        i.staleFiles = [stale(.gone)]
        let r = try result(.staleFiles, i)
        #expect(r.status == .ok && r.fix == nil && r.detail.contains("next start"))
    }

    @Test func aFailedPidFileListIsSkippedNotOk() throws {
        var i = DoctorFixture.healthy()
        i.staleListFailure = 127
        let r = try result(.staleFiles, i)
        #expect(r.status == .skipped && r.detail.contains("exit 127") && r.fix == nil)
    }

    @Test func linesOfThePidFileListThatCannotBeReadAreAWarning() throws {
        var i = DoctorFixture.healthy()
        i.staleUnparsed = 2
        let r = try result(.staleFiles, i)
        #expect(r.status == .warning && r.detail.contains("2 line"))
        // A reused file is the stronger finding.
        i.staleFiles = [stale(.reused)]
        #expect(try result(.staleFiles, i).status == .problem)
    }

    @Test func theDaemonPidFileIsNamedWithTheHomeAsTilde() throws {
        var i = DoctorFixture.healthy()
        i.staleFiles = [
            StaleLimaFile(reason: .reused, path: "\(home)/.colima/default/daemon/daemon.pid", pid: "9")
        ]
        let r = try result(.staleFiles, i)
        #expect(r.detail.contains("~/.colima/default/daemon/daemon.pid") && r.fix == .repair)
    }

    @Test func manyFilesAreCountedInTheDetail() throws {
        var i = DoctorFixture.healthy()
        i.staleFiles = (0..<5).map { stale(.reused, "colima/f\($0).pid") }
        #expect(try result(.staleFiles, i).detail.contains("and 2 more"))
    }

    // MARK: diskSpace

    @Test func theWorstOfTheVMAndTheMacDecidesTheDiskStatus() throws {
        var i = DoctorFixture.healthy()
        i.disk.vm = .init(usedKB: 96_000_000, availKB: 4_000_000)
        #expect(try result(.diskSpace, i).status == .problem)
        i = DoctorFixture.healthy()
        i.disk.macFreeBytes = 10 * DiskSpace.gigabyte
        let r = try result(.diskSpace, i)
        #expect(r.status == .warning && r.detail.contains("Mac"))
    }

    @Test func aFailedDiskCommandOfARunningVMIsAWarningNotStopped() throws {
        var i = DoctorFixture.healthy()
        i.disk.vm = nil
        i.disk.vmError = "colima ssh df failed (exit 255)"
        let r = try result(.diskSpace, i)
        #expect(r.status == .warning && r.detail.contains("exit 255") && !r.detail.contains("stopped"))
    }

    @Test func aStoppedVMSkipsOnlyTheVMDisk() throws {
        var i = DoctorFixture.healthy()
        i.disk.vm = nil
        let r = try result(.diskSpace, i)
        #expect(r.status == .ok && r.detail.contains("stopped"))
        i.disk.macFreeBytes = nil
        #expect(try result(.diskSpace, i).status == .skipped)
    }

    // MARK: stopped hint

    @Test func theStoppedHintNamesABrokenProfileOrAFailedStart() {
        #expect(DoctorRules.stoppedHint(status: "Broken", startFailed: false)?.contains("Broken") == true)
        #expect(DoctorRules.stoppedHint(status: "Stopped", startFailed: true)?.contains("failed") == true)
        #expect(DoctorRules.stoppedHint(status: "Stopped", startFailed: false) == nil)
        #expect(DoctorRules.stoppedHint(status: nil, startFailed: false) == nil)
    }
}
