import Foundation
import Testing

@testable import ColimaBar

@Suite @MainActor struct ColimaModelCleanupTests {
    private let id = String(repeating: "c1", count: 32)

    private func df() throws -> APIDF {
        try DFFixture.df(
            images: [
                DFFixture.image("sha256:" + String(repeating: "1", count: 64), tags: ["web:1"], size: 1000),
                DFFixture.image(
                    "sha256:" + String(repeating: "2", count: 64), tags: ["db:1"], size: 500, containers: 1),
            ],
            containers: [DFFixture.container(id, name: "api", state: "running", size: 40)],
            volumes: [DFFixture.volume("pgdata", size: 300)], cache: [DFFixture.cache("a", size: 200)])
    }

    @Test func applyDFBuildsTheReportAndKeepsTheDiskUsageRows() throws {
        let model = ColimaModel(profile: "cleanup-test-profile", readOnly: true)
        model.applyDF(try df())
        #expect(model.df.map(\.type) == ["Images", "Containers", "Volumes", "Build cache"])
        #expect(model.df.first?.size == 1500)
        #expect(model.images.count == 2)
        #expect(model.volumes.map(\.name) == ["pgdata"])
        #expect(model.cleanup.images.count == 2)
        #expect(model.cleanup.volumes.items.map(\.title) == ["pgdata"])
        #expect(model.cleanup.containerNames[id] == "api")
    }

    @Test func theLogRowsFollowTheSizesAndTheReport() throws {
        let model = ColimaModel(profile: "cleanup-test-profile", readOnly: true)
        model.setLogSizes([id: 77], error: nil)
        #expect(model.logItems.isEmpty)  // the report does not know the container yet
        model.applyDF(try df())
        #expect(model.logItems.items.map(\.title) == ["api"])
        model.setLogSizes(nil, error: "x")
        #expect(model.logItems.isEmpty)
        #expect(model.logSizesError == "x")
    }

    @Test func aFixtureLoadsOnlyInADebugRun() throws {
        let body = DFFixture.body(volumes: [DFFixture.volume("pgdata", size: 300)])
        let json = #"{"df":\#(body),"logs":{"\#(id)":5},"diskImage":{"allocated":100,"apparent":200}}"#
        let debug = ColimaModel(profile: "cleanup-test-profile", readOnly: true)
        #expect(debug.loadCleanupFixture(Data(json.utf8)))
        #expect(debug.cleanupFixtureLoaded)
        #expect(debug.cleanup.volumes.items.map(\.title) == ["pgdata"])
        #expect(debug.logSizes == [id: 5])
        #expect(debug.diskImage == DiskImageSize(allocated: 100, apparent: 200))

        let normal = ColimaModel(profile: "cleanup-test-profile")
        #expect(!normal.loadCleanupFixture(Data(json.utf8)))
        #expect(!normal.cleanupFixtureLoaded && normal.cleanup.isEmpty && normal.diskImage == nil)
        #expect(!debug.loadCleanupFixture(Data("not json".utf8)))
    }

    @Test func trimAndTruncateDoNothingInADebugRun() {
        let model = ColimaModel(profile: "cleanup-test-profile", readOnly: true)
        #expect(!model.canTrim)
        model.trimDisk()
        #expect(!model.isTrimming)
        let item = CleanupItem(
            id: "log:x", kind: .log, title: "api", detail: "", size: 1, inUse: false,
            removal: .init(action: .logTruncate, args: [id, "api"]))
        model.truncateLog(item)
        #expect(model.busy == nil)
    }

    @Test func aStoppedVMCannotTrim() {
        let model = ColimaModel(profile: "cleanup-test-profile")
        #expect(!model.canTrim)
    }

    // MARK: - Log check

    /// Counts the calls of a replaced probe.
    private final class ProbeCalls: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        var count: Int { lock.withLock { n } }
        func hit() { lock.withLock { n += 1 } }
    }

    private func runningModel(_ probe: ProbeCalls, answer: CleanupProbe.LogCheck) -> ColimaModel {
        let model = ColimaModel(profile: "cleanup-test-profile", readOnly: true)
        model.setState(.running)
        model.logProbe = { _ in
            probe.hit()
            return answer
        }
        return model
    }

    @Test func aStoppedVMReadsNoLogSizes() async {
        let calls = ProbeCalls()
        let model = runningModel(calls, answer: .sizes([:]))
        model.setState(.stopped)
        await model.refreshLogSizes()
        #expect(calls.count == 0 && !model.logSizesChecking && model.logSizesCheckedAt == nil)
    }

    @Test func aLogCheckStoresTheSizesAndWaitsSixtySecondsUnlessForced() async {
        let calls = ProbeCalls()
        let model = runningModel(calls, answer: .sizes([id: 9]))
        await model.refreshLogSizes()
        #expect(model.logSizes == [id: 9] && model.logSizesError == nil && !model.logSizesChecking)
        #expect(model.logSizesCheckedAt != nil)
        await model.refreshLogSizes()
        #expect(calls.count == 1)
        model.logSizesCheckedAt = Date().addingTimeInterval(-ColimaModel.logSizesMinGap - 1)
        await model.refreshLogSizes()
        #expect(calls.count == 2)
        await model.refreshLogSizes(force: true)
        #expect(calls.count == 3)
    }

    @Test func aFailedLogCheckKeepsTheCauseAndTheOldSizes() async {
        let calls = ProbeCalls()
        let model = runningModel(calls, answer: .failed(detail: "sudo: a password is required"))
        model.setLogSizes([id: 4], error: nil)
        await model.refreshLogSizes()
        #expect(model.logSizes == [id: 4])
        let error = model.logSizesError ?? ""
        #expect(error.hasPrefix("ColimaBar could not read the log files in the VM."))
        #expect(error.contains("sudo") && error.contains("a password is required"))
        #expect(model.logSizesCheckedAt != nil)
    }

    @Test func aCancelledLogCheckIsNoFailureAndNoCheck() async {
        let model = ColimaModel(profile: "cleanup-test-profile", readOnly: true)
        model.setState(.running)
        model.logProbe = { _ in
            try? await Task.sleep(for: .seconds(30))
            return .failed(detail: "late")
        }
        let task = Task { await model.refreshLogSizes() }
        #expect(await waitUntil { model.logSizesChecking })
        task.cancel()
        await task.value
        #expect(!model.logSizesChecking && model.logSizesError == nil && model.logSizesCheckedAt == nil)
    }

    @Test func aFixtureStopsTheLogCheck() async throws {
        let calls = ProbeCalls()
        let model = runningModel(calls, answer: .sizes([id: 1]))
        let json = #"{"df":\#(DFFixture.body())}"#
        #expect(model.loadCleanupFixture(Data(json.utf8)))
        await model.refreshLogSizes(force: true)
        #expect(calls.count == 0)
    }

    @Test func clearingTheVMDataResetsTheLogCheck() {
        let model = ColimaModel(profile: "cleanup-test-profile", readOnly: true)
        model.setLogSizes([id: 1], error: "x")
        model.setLogSizesChecking(true)
        model.logSizesCheckedAt = Date()
        model.clearVMData(because: .vmStopped)
        #expect(model.logSizes == nil && model.logSizesError == nil && !model.logSizesChecking)
        #expect(model.logSizesCheckedAt == nil && model.logItems.isEmpty && model.cleanup.isEmpty)
    }

    // MARK: - Weekly cleanup

    private func dueModel() -> ColimaModel {
        let model = ColimaModel(profile: "cleanup-test-profile")
        model.setState(.running)
        model.scheduledPrune = true
        return model
    }

    @Test func aDueWeeklyCleanupStartsOnceAndHoldsTheProfileBackForAnHour() {
        let model = dueModel()
        defer { model.scheduledPrune = false }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(model.claimScheduledPrune(now: now))
        #expect(model.pruneRetryAt["cleanup-test-profile"] == now.addingTimeInterval(PruneSchedule.retryAfter))
        #expect(!model.claimScheduledPrune(now: now.addingTimeInterval(60)))
        #expect(model.claimScheduledPrune(now: now.addingTimeInterval(PruneSchedule.retryAfter + 1)))
    }

    @Test func aWeeklyCleanupWaitsWhileTheVMIsNotRunningOrTheSettingIsOff() {
        let model = dueModel()
        defer { model.scheduledPrune = false }
        let now = Date()
        model.setState(.stopped)
        #expect(!model.claimScheduledPrune(now: now))
        model.setState(.running)
        model.setTrimming(true)
        #expect(!model.claimScheduledPrune(now: now))
        model.setTrimming(false)
        model.scheduledPrune = false
        #expect(!model.claimScheduledPrune(now: now))
        #expect(model.pruneRetryAt.isEmpty)
    }

    @Test func turningTheSettingOffClearsTheWaits() {
        let model = dueModel()
        defer { model.scheduledPrune = false }
        model.pruneRetryAt = ["cleanup-test-profile": Date().addingTimeInterval(3600)]
        model.scheduledPrune = false
        #expect(model.pruneRetryAt.isEmpty)
    }

    // MARK: - df

    @Test func theCleanupPageWantsTheDiskUseLikeADiskTab() {
        func wants(
            tab: DashboardTab = .containers, page: Bool = false, running: Bool = true, docker: Bool = true,
            fixture: Bool = false, visible: Bool = true
        ) -> Bool {
            ColimaModel.wantsDF(
                visible: visible, tab: tab, cleanupOnScreen: page, running: running, hasDockerSocket: docker,
                fixtureLoaded: fixture)
        }
        #expect(!wants())
        #expect(wants(page: true))
        #expect(wants(tab: .system))
        #expect(!wants(page: true, running: false))
        #expect(!wants(page: true, docker: false))
        #expect(!wants(page: true, fixture: true))
        #expect(!wants(page: true, visible: false))
    }
}
