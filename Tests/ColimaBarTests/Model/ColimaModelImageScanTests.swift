import Foundation
import Testing

@testable import ColimaBar

/// The image scan of the model, with a fake daemon, a fake scanner and a
/// temporary work folder. No test exports from a real VM or runs a real scanner.
@MainActor @Suite struct ColimaModelImageScanTests {
    private let hex = String(repeating: "cd", count: 32)

    @MainActor private final class Rig {
        let folder: TempFolder
        let daemon: FakeDaemon
        let scanner = FakeScanner()
        let model: ColimaModel
        var notices: [String] = []

        init(
            hex: String, readOnly: Bool = false, running: Bool = true, tools: [String] = ["trivy"],
            enabled: Bool = true, holdExport: Bool = false
        ) throws {
            folder = try TempFolder()
            let tar =
                TarFixture.entry("blobs/sha256/abc", content: String(repeating: "x", count: 3000))
                + TarFixture.entry("manifest.json", content: "[]") + TarFixture.endMarker
            daemon = FakeDaemon(path: TestSocketPath.unique()) { req in
                if req.line.hasPrefix("GET /images/get") {
                    return .init(chunks: [holdExport ? Data(tar.prefix(2000)) : tar], holdOpen: holdExport)
                }
                if req.line.hasPrefix("GET /images/") {
                    return .init(body: Data(#"{"Id":"sha256:\#(hex)","Size":10000}"#.utf8))
                }
                return .init(status: 404)
            }
            try daemon.start()
            model = ColimaModel(
                profile: "scan-\(UUID().uuidString.prefix(6))", readOnly: readOnly,
                dockerAPI: DockerAPI(socketPath: daemon.path))
            model.setState(running ? .running : .stopped)
            model.scannerLocator = { tools.contains($0) ? "/opt/homebrew/bin/\($0)" : nil }
            model.scanRun = scanner.run
            model.scanDir = folder.path + "/scan"
            model.scanOnline = { true }
            model.scanHasDatabase = { _ in true }
            model.scanFreeSpace = { nil }
            model.refreshScanners()
            model.imageScanEnabled = enabled
            model.notifySink = { [weak self] in self?.notices.append($0) }
        }

        deinit { daemon.stop() }

        var files: [String] { (try? FileManager.default.contentsOfDirectory(atPath: folder.path + "/scan")) ?? [] }
    }

    private func finished(_ m: ColimaModel) async -> Bool {
        await waitUntil { m.imageScanState?.isRunning == false }
    }

    // MARK: - Gates

    @Test func withTheSettingOffNothingRuns() throws {
        let rig = try Rig(hex: hex, enabled: false)
        #expect(rig.model.showsImageScan)
        #expect(!rig.model.imageScanOn)
        #expect(!rig.model.canScanImages)
        rig.model.startImageScan(imageID: hex, name: "nginx:latest")
        #expect(rig.model.imageScanState == nil)
        #expect(rig.daemon.seen.isEmpty)
        #expect(rig.scanner.calls.isEmpty)
    }

    @Test func withNoScannerTheSettingIsHiddenAndNothingRuns() throws {
        let rig = try Rig(hex: hex, tools: [])
        #expect(!rig.model.showsImageScan)
        #expect(rig.model.activeScanner == nil)
        rig.model.startImageScan(imageID: hex, name: "nginx:latest")
        #expect(rig.model.imageScanState == nil)
        #expect(rig.daemon.seen.isEmpty)
    }

    @Test func aDebugRunNeverExportsAndNeverRunsAScanner() throws {
        let rig = try Rig(hex: hex, readOnly: true)
        #expect(!rig.model.canScanImages)
        rig.model.startImageScan(imageID: hex, name: "nginx:latest")
        #expect(rig.model.imageScanState == nil)
        #expect(rig.daemon.seen.isEmpty)
        #expect(rig.scanner.calls.isEmpty)
        #expect(rig.model.imageScanTask == nil)
    }

    @Test func aStoppedVMNeverScans() throws {
        let rig = try Rig(hex: hex, running: false)
        rig.model.startImageScan(imageID: hex, name: "nginx:latest")
        #expect(rig.model.imageScanState == nil)
        #expect(rig.daemon.seen.isEmpty)
    }

    @Test func anIDThatIsNotHexNeverReachesTheDaemon() throws {
        let rig = try Rig(hex: hex)
        rig.model.startImageScan(imageID: "../../etc", name: "x")
        rig.model.startImageScan(imageID: "", name: "x")
        #expect(rig.model.imageScanState == nil)
        #expect(rig.daemon.seen.isEmpty)
    }

    @Test func thePickedScannerCountsOnlyIfItExists() throws {
        let both = try Rig(hex: hex, tools: ["trivy", "grype"])
        #expect(both.model.showsScannerPicker)
        #expect(both.model.activeScanner == .trivy)
        both.model.imageScanTool = .grype
        #expect(both.model.activeScanner == .grype)
        let one = try Rig(hex: hex, tools: ["trivy"])
        one.model.imageScanTool = .grype
        #expect(!one.model.showsScannerPicker)
        #expect(one.model.activeScanner == .trivy)
    }

    // MARK: - Run

    @Test func aScanGivesAReportAndLeavesNoFile() async throws {
        let rig = try Rig(hex: hex)
        rig.scanner.report =
            #"{"Results":[{"Vulnerabilities":[{"VulnerabilityID":"CVE-1","PkgName":"a","Severity":"CRITICAL"}]}]}"#
        rig.model.startImageScan(imageID: "sha256:" + hex, name: "nginx:latest")
        #expect(await finished(rig.model))
        let report = try #require(rig.model.imageScanReport(forImageID: hex))
        #expect(report.badgeText == "1 critical")
        #expect(rig.model.imageScanState?.report == report)
        #expect(rig.model.imageScanState(forImageID: "sha256:" + hex)?.imageName == "nginx:latest")
        #expect(rig.scanner.calls.count == 1)
        #expect(rig.scanner.calls.first?.first == "trivy")
        #expect(report.toolVersion == "1.2.3")
        #expect(rig.scanner.versionCalls == [["trivy", "--version", "-f", "json"]])
        #expect(rig.scanner.versionEnvironments == [ImageScanner.trivy.environment(offline: false)])
        #expect(rig.model.busyActions(rig.model.profile) == 0)
        #expect(rig.files.isEmpty)
        #expect(rig.notices.isEmpty)
        #expect(rig.model.canScanImages)
    }

    @Test func aSecondScanWaitsForTheFirst() async throws {
        let rig = try Rig(hex: hex)
        rig.scanner.hold = true
        rig.model.startImageScan(imageID: hex, name: "a")
        #expect(await waitUntil { rig.scanner.calls.count == 1 })
        #expect(!rig.model.canScanImages)
        rig.model.startImageScan(imageID: hex, name: "b")
        rig.model.cancelImageScan()
        #expect(await finished(rig.model))
        #expect(rig.scanner.calls.count == 1)
        #expect(rig.model.imageScanState?.phase == .failed(.cancelled))
        #expect(rig.notices.isEmpty)
        #expect(rig.files.isEmpty)
        #expect(rig.model.canScanImages)
    }

    @Test func aFailureTellsTheUserWhenThePageIsNotOnScreen() async throws {
        let rig = try Rig(hex: hex)
        rig.scanner.status = 1
        rig.scanner.log = "FATAL boom"
        rig.model.startImageScan(imageID: hex, name: "nginx:latest")
        #expect(await finished(rig.model))
        #expect(rig.model.imageScanState?.phase == .failed(.other("FATAL boom")))
        #expect(rig.notices == ["Scan of nginx:latest failed: FATAL boom"])
        #expect(rig.model.imageScanReport(forImageID: hex) == nil)
    }

    @Test func aFailureStaysQuietWhileThePageIsOnScreen() async throws {
        let rig = try Rig(hex: hex)
        rig.scanner.status = 1
        rig.scanner.log = "FATAL boom"
        rig.scanner.hold = true
        rig.model.imageScanOnScreen = true
        rig.model.startImageScan(imageID: hex, name: "nginx:latest")
        #expect(await waitUntil { rig.model.imageScanState?.phase == .scanning(firstRun: false) })
        // The dashboard opens while the scanner runs. It does not end this scan.
        rig.model.visibleCount = 1
        rig.scanner.release()
        #expect(await finished(rig.model))
        #expect(rig.model.imageScanState?.phase == .failed(.other("FATAL boom")))
        #expect(rig.notices.isEmpty)
    }

    @Test func aReportBelongsToItsProfile() async throws {
        let rig = try Rig(hex: hex)
        rig.model.startImageScan(imageID: hex, name: "nginx:latest")
        #expect(await finished(rig.model))
        let reports = rig.model.imageScanReports
        let mine = rig.model.profile
        #expect(ColimaModel.scanReport(in: reports, profile: mine, imageID: hex) != nil)
        #expect(ColimaModel.scanReport(in: reports, profile: "other", imageID: hex) == nil)
        #expect(ColimaModel.scanReport(in: reports, profile: mine, imageID: "sha256:" + hex) != nil)
    }

    @Test func aFinishedReportSurvivesAProfileSwitch() async throws {
        let rig = try Rig(hex: hex)
        rig.model.startImageScan(imageID: hex, name: "nginx:latest")
        #expect(await finished(rig.model))
        let key = "\(rig.model.profile)/\(hex)"
        #expect(rig.model.imageScanReports[key] != nil)
        rig.model.dropDataOfOldSocket()
        #expect(rig.model.imageScanReports[key] != nil)
    }

    @Test func aQuitDuringTheScanEndsItAndDeletesTheFilesAtOnce() async throws {
        let rig = try Rig(hex: hex)
        rig.scanner.hold = true
        rig.model.startImageScan(imageID: hex, name: "x")
        #expect(await waitUntil { rig.scanner.calls.count == 1 && !rig.files.isEmpty })
        rig.model.stopImageScanForQuit()
        #expect(rig.files.isEmpty)
        #expect(await finished(rig.model))
        #expect(rig.model.imageScanState?.phase == .failed(.cancelled))
        #expect(rig.files.isEmpty)
    }

    @Test func aQuitDuringTheExportEndsItAndDeletesTheFilesAtOnce() async throws {
        let rig = try Rig(hex: hex, holdExport: true)
        rig.model.startImageScan(imageID: hex, name: "x")
        #expect(await waitUntil { rig.model.busyActions(rig.model.profile) == 1 && !rig.files.isEmpty })
        rig.model.stopImageScanForQuit()
        #expect(rig.files.isEmpty)
        #expect(await finished(rig.model))
        #expect(rig.scanner.calls.isEmpty)
    }

    @Test func scanAgainRunsTheSameImageAgain() async throws {
        let rig = try Rig(hex: hex)
        rig.model.startImageScan(imageID: hex, name: "nginx:latest")
        #expect(await finished(rig.model))
        rig.model.scanAgain(imageID: hex)
        #expect(await waitUntil { rig.scanner.calls.count == 2 })
        #expect(await finished(rig.model))
        #expect(rig.model.imageScanState?.imageName == "nginx:latest")
    }

    @Test func scanAgainOfAnImageWithNoScanDoesNothing() async throws {
        let rig = try Rig(hex: hex)
        rig.model.scanAgain(imageID: hex)
        rig.model.startImageScan(imageID: hex, name: "nginx:latest")
        #expect(await finished(rig.model))
        let other = String(repeating: "ef", count: 32)
        rig.model.scanAgain(imageID: other)
        #expect(rig.scanner.calls.count == 1)
        #expect(rig.daemon.seen.filter { $0.contains(other) }.isEmpty)
    }

    @Test func theExportHoldsAutoStopAndTheWeeklyCleanupOnly() async throws {
        let rig = try Rig(hex: hex, holdExport: true)
        rig.model.startImageScan(imageID: hex, name: "x")
        #expect(await waitUntil { rig.model.busyActions(rig.model.profile) == 1 })
        rig.model.cancelImageScan()
        #expect(await finished(rig.model))
        #expect(rig.model.busyActions(rig.model.profile) == 0)
        #expect(rig.files.isEmpty)
    }

    @Test func theScannerPhaseHoldsNothing() async throws {
        let rig = try Rig(hex: hex)
        rig.scanner.hold = true
        rig.model.startImageScan(imageID: hex, name: "x")
        #expect(await waitUntil { rig.scanner.calls.count == 1 })
        #expect(await waitUntil { rig.model.busyActions(rig.model.profile) == 0 })
        rig.model.cancelImageScan()
        #expect(await finished(rig.model))
    }

    // MARK: - VM and profile changes

    @Test func aVMStopDuringTheExportCancelsTheScan() async throws {
        let rig = try Rig(hex: hex, holdExport: true)
        rig.model.startImageScan(imageID: hex, name: "x")
        #expect(await waitUntil { rig.model.busyActions(rig.model.profile) == 1 })
        let task = rig.model.imageScanTask
        rig.model.clearVMData(because: .vmStopped)
        #expect(rig.model.imageScanState == nil)
        await task?.value
        #expect(rig.model.imageScanState == nil)
        #expect(rig.model.busyActions(rig.model.profile) == 0)
        #expect(rig.scanner.calls.isEmpty)
        #expect(rig.files.isEmpty)
    }

    @Test func aVMStopAfterTheExportDoesNotEndTheScan() async throws {
        let rig = try Rig(hex: hex)
        rig.scanner.hold = true
        rig.model.startImageScan(imageID: hex, name: "x")
        #expect(await waitUntil { rig.model.imageScanState?.phase == .scanning(firstRun: false) })
        rig.model.clearVMData(because: .vmStopped)
        #expect(rig.model.imageScanState?.isRunning == true)
        rig.model.cancelImageScan()
        #expect(await finished(rig.model))
    }

    @Test func aProfileSwitchDropsTheScanAndItsLateResult() async throws {
        let rig = try Rig(hex: hex)
        rig.scanner.hold = true
        rig.model.startImageScan(imageID: hex, name: "x")
        #expect(await waitUntil { rig.scanner.calls.count == 1 })
        let task = rig.model.imageScanTask
        rig.model.dropDataOfOldSocket()
        #expect(rig.model.imageScanState == nil)
        await task?.value
        #expect(rig.model.imageScanState == nil)
        #expect(rig.model.imageScanReports.isEmpty)
        #expect(rig.notices.isEmpty)
    }

    @Test func turningTheSettingOffForgetsTheScanAndTheReports() async throws {
        let rig = try Rig(hex: hex)
        rig.model.startImageScan(imageID: hex, name: "x")
        #expect(await finished(rig.model))
        #expect(rig.model.imageScanReport(forImageID: hex) != nil)
        rig.model.imageScanEnabled = false
        #expect(rig.model.imageScanReport(forImageID: hex) == nil)
        #expect(rig.model.imageScanState == nil)
    }

    // MARK: - Network and database

    @Test func offlineWithNoDatabaseStopsBeforeTheExport() async throws {
        let rig = try Rig(hex: hex)
        rig.model.scanOnline = { false }
        rig.model.scanHasDatabase = { _ in false }
        rig.model.startImageScan(imageID: hex, name: "x")
        #expect(await finished(rig.model))
        #expect(rig.model.imageScanState?.phase == .failed(.noDatabase))
        #expect(rig.daemon.seen.isEmpty)
        #expect(rig.scanner.calls.isEmpty)
    }

    @Test func offlineWithADatabaseScansWithoutAnUpdate() async throws {
        let rig = try Rig(hex: hex)
        rig.model.scanOnline = { false }
        rig.model.startImageScan(imageID: hex, name: "x")
        #expect(await finished(rig.model))
        #expect(rig.scanner.calls.first?.contains("--skip-db-update") == true)
    }

    @Test func aFirstScanSaysThatItDownloadsTheDatabase() async throws {
        let rig = try Rig(hex: hex)
        rig.model.scanHasDatabase = { _ in false }
        rig.scanner.hold = true
        rig.model.startImageScan(imageID: hex, name: "x")
        #expect(await waitUntil { rig.model.imageScanState?.phase == .scanning(firstRun: true) })
        #expect(rig.model.imageScanState?.statusLine?.hasPrefix("Downloading the vulnerability database") == true)
        rig.model.cancelImageScan()
        #expect(await finished(rig.model))
    }

    // MARK: - Settings and leftovers

    @Test func theSettingsTransferCarriesTheSettingAndTheScanner() throws {
        let rig = try Rig(hex: hex, tools: ["trivy", "grype"], enabled: false)
        #expect(rig.model.settingsSnapshot[.imageScan] == .bool(false))
        #expect(rig.model.settingsSnapshot[.imageScanner] == .string("trivy"))
        #expect(
            rig.model.apply(SettingsTransfer.Change(setting: .imageScan, from: .bool(false), to: .bool(true))) == nil)
        #expect(
            rig.model.apply(
                SettingsTransfer.Change(setting: .imageScanner, from: .string("trivy"), to: .string("grype"))) == nil)
        #expect(rig.model.imageScanEnabled)
        #expect(rig.model.imageScanTool == .grype)
        #expect(
            rig.model.apply(SettingsTransfer.Change(setting: .imageScanner, from: nil, to: .string("rm -rf")))
                != nil)
        #expect(rig.model.imageScanTool == .grype)
    }

    @Test func aNormalRunRemovesTheLeftoversOfAnEarlierRunButADebugRunDoesNot() throws {
        let rig = try Rig(hex: hex)
        try FileManager.default.createDirectory(atPath: rig.folder.path + "/scan", withIntermediateDirectories: true)
        try Data("x".utf8).write(to: URL(fileURLWithPath: rig.folder.path + "/scan/old.tar"))
        let debug = try Rig(hex: hex, readOnly: true)
        try FileManager.default.createDirectory(atPath: debug.folder.path + "/scan", withIntermediateDirectories: true)
        try Data("x".utf8).write(to: URL(fileURLWithPath: debug.folder.path + "/scan/old.tar"))
        debug.model.removeScanLeftovers()
        #expect(debug.files == ["old.tar"])
        rig.model.removeScanLeftovers()
        #expect(rig.files.isEmpty)
    }

    // MARK: - Fixture

    private func fixture(_ ref: String) -> Data {
        Data(
            """
            {"tool":"grype","available":["trivy","grype"],"reports":{"\(ref)":{"version":"0.121.0","findings":[
              {"id":"CVE-1","package":"zlib","installed":"1","fixed":"2","severity":"high","title":"Flaw"}]}}}
            """.utf8)
    }

    private func withImage(_ m: ColimaModel) throws {
        m.applyDF(
            try DFFixture.df(
                images: [DFFixture.image("sha256:" + hex, tags: ["nginx:latest"], size: 1000)], containers: [],
                volumes: [], cache: []))
    }

    @Test func theFixtureLoadsOnlyInADebugRun() throws {
        let normal = try Rig(hex: hex, tools: [], enabled: false)
        try withImage(normal.model)
        #expect(!normal.model.loadImageScanFixture(fixture("nginx:latest")))
        #expect(normal.model.imageScanReports.isEmpty)
        #expect(!normal.model.imageScanEnabled)

        let debug = try Rig(hex: hex, readOnly: true, tools: [], enabled: false)
        try withImage(debug.model)
        #expect(debug.model.loadImageScanFixture(fixture("nginx:latest")))
        #expect(debug.model.imageScanEnabled)
        #expect(debug.model.scannersAvailable == [.trivy, .grype])
        #expect(debug.model.activeScanner == .grype)
        let report = try #require(debug.model.imageScanReport(forImageID: hex))
        #expect(report.imageName == "nginx:latest")
        #expect(report.toolVersion == "0.121.0")
        #expect(report.findings.map(\.severity) == [.high])
        debug.model.refreshScanners()
        #expect(debug.model.scannersAvailable == [.trivy, .grype])
        #expect(!debug.model.loadImageScanFixture(Data("nope".utf8)))
        #expect(debug.daemon.seen.isEmpty)
        #expect(debug.scanner.calls.isEmpty)
    }

    @Test func theFixtureReportsFollowTheNextRefreshOfTheImageList() throws {
        let debug = try Rig(hex: hex, readOnly: true)
        #expect(debug.model.loadImageScanFixture(fixture("nginx:latest")))
        #expect(debug.model.imageScanReports.isEmpty)
        try withImage(debug.model)
        #expect(debug.model.imageScanReport(forImageID: hex) != nil)
        try withImage(debug.model)
        #expect(debug.model.imageScanReport(forImageID: hex) != nil)
    }

    @Test func theFixtureSkipsAnImageThatTheVMDoesNotHave() throws {
        let debug = try Rig(hex: hex, readOnly: true)
        try withImage(debug.model)
        #expect(debug.model.loadImageScanFixture(fixture("redis:7")))
        #expect(debug.model.imageScanReports.isEmpty)
    }
}
