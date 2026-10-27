import Foundation
import Testing

@testable import ColimaBar

@Suite struct ImageScanRunnerTests {
    private let hex = String(repeating: "ab", count: 32)
    private let trivyReport =
        #"{"Results":[{"Vulnerabilities":[{"VulnerabilityID":"CVE-1","PkgName":"a","InstalledVersion":"1","Severity":"HIGH"}]}]}"#

    private struct Scenario {
        var size = 10_000
        var archive: [Data] = []
        var inspectStatus = 200
        var getStatus = 200
        var holdOpen = false
    }

    private func daemon(_ s: Scenario) throws -> FakeDaemon {
        let id = hex
        let d = FakeDaemon(path: TestSocketPath.unique()) { req in
            if req.line.hasPrefix("GET /images/get") {
                if s.getStatus != 200 { return .init(status: s.getStatus, body: Data(#"{"message":"boom"}"#.utf8)) }
                return .init(chunks: s.archive, holdOpen: s.holdOpen)
            }
            if req.line.hasPrefix("GET /images/") {
                return .init(
                    status: s.inspectStatus, body: Data(#"{"Id":"sha256:\#(id)","Size":\#(s.size)}"#.utf8))
            }
            return .init(status: 404)
        }
        try d.start()
        return d
    }

    private func tar(index: Bool = false) -> Data {
        TarFixture.entry("blobs/sha256/abc", content: String(repeating: "x", count: 3000))
            + TarFixture.entry(index ? "index.json" : "manifest.json", content: "[]") + TarFixture.endMarker
    }

    private func runner(
        _ d: FakeDaemon, _ folder: TempFolder, _ scanner: FakeScanner, free: Int64? = nil,
        stall: TimeInterval = ImageScanRules.exportStall
    ) -> ImageScanRunner {
        ImageScanRunner(
            api: DockerAPI(socketPath: d.path), dir: folder.path + "/scan", run: scanner.run, freeSpace: { free },
            stall: stall)
    }

    private func job(_ tool: ImageScanner = .trivy, offline: Bool = false, firstRun: Bool = false)
        -> ImageScanRunner.Job
    {
        .init(
            imageID: hex, name: "nginx:latest", scanner: tool, version: "0.76.1", offline: offline, firstRun: firstRun)
    }

    private func files(_ folder: TempFolder) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: folder.path + "/scan")) ?? []
    }

    private func failure(_ result: Result<ImageScanReport, ImageScanError>) -> ImageScanError? {
        if case .failure(let error) = result { return error }
        return nil
    }

    // MARK: Success

    @Test func aScanExportsTheImageRunsTheScannerOnTheFileAndDeletesBothFiles() async throws {
        let d = try daemon(Scenario(archive: [tar()]))
        defer { d.stop() }
        let folder = try TempFolder()
        let scanner = FakeScanner()
        scanner.report = trivyReport
        let phases = Box<[ImageScanState.Phase]>([])
        let result = await runner(d, folder, scanner).scan(job(firstRun: true)) { phase in
            phases.mutate { $0.append(phase) }
        }
        let report = try result.get()
        #expect(report.findings.map(\.vulnID) == ["CVE-1"])
        #expect(report.tool == .trivy)
        #expect(report.toolVersion == "0.76.1")
        #expect(report.imageID == hex)
        #expect(report.imageName == "nginx:latest")
        #expect(d.seen.first == "GET /images/\(hex)/json HTTP/1.0")
        #expect(d.seen.last == "GET /images/get?names=sha256%3A\(hex) HTTP/1.0")
        #expect(scanner.calls.count == 1)
        #expect(scanner.inputExisted == [true])
        #expect(scanner.timeouts == [ImageScanRules.scanTimeout])
        #expect(files(folder).isEmpty)
        #expect(phases.value.first == .exporting(bytes: 0, total: 10_000))
        #expect(phases.value.last == .scanning(firstRun: true))
        let args = try #require(scanner.calls.first)
        #expect(args.first == "trivy")
        #expect(args.contains("--offline-scan"))
        #expect(!args.contains("--skip-db-update"))
    }

    @Test func theWorkFolderIsPrivate() async throws {
        let d = try daemon(Scenario(archive: [tar()]))
        defer { d.stop() }
        let folder = try TempFolder()
        _ = await runner(d, folder, FakeScanner()).scan(job()) { _ in }
        var st = stat()
        #expect(stat(folder.path + "/scan", &st) == 0)
        #expect(st.st_mode & 0o777 == 0o700)
    }

    @Test func offlineGivesTheScannerTheSkipFlags() async throws {
        let d = try daemon(Scenario(archive: [tar()]))
        defer { d.stop() }
        let folder = try TempFolder()
        let scanner = FakeScanner()
        _ = await runner(d, folder, scanner).scan(job(.grype, offline: true)) { _ in }
        #expect(scanner.environments.first?["GRYPE_DB_AUTO_UPDATE"] == "false")
        #expect(scanner.calls.first?[1].hasPrefix("docker-archive:") == true)
    }

    @Test func grypeGetsAnOCILayoutByItsName() async throws {
        let d = try daemon(Scenario(archive: [tar(index: true)]))
        defer { d.stop() }
        let folder = try TempFolder()
        let scanner = FakeScanner()
        scanner.report = #"{"matches":[]}"#
        let result = await runner(d, folder, scanner).scan(job(.grype)) { _ in }
        #expect(try result.get().isClean)
        #expect(scanner.calls.first?[1].hasPrefix("oci-archive:") == true)
    }

    // MARK: Failures

    @Test func aFailedScannerGivesItsLastLineAndLeavesNoFile() async throws {
        let d = try daemon(Scenario(archive: [tar()]))
        defer { d.stop() }
        let folder = try TempFolder()
        let scanner = FakeScanner()
        scanner.status = 1
        scanner.log = "start\nFATAL boom\n"
        let result = await runner(d, folder, scanner).scan(job()) { _ in }
        #expect(failure(result) == .other("FATAL boom"))
        #expect(files(folder).isEmpty)
    }

    @Test func aScannerThatCannotStartMeansTheToolIsGone() async throws {
        let d = try daemon(Scenario(archive: [tar()]))
        defer { d.stop() }
        let folder = try TempFolder()
        let scanner = FakeScanner()
        scanner.status = -1
        #expect(failure(await runner(d, folder, scanner).scan(job()) { _ in }) == .toolMissing)
    }

    @Test(arguments: [nil, "not json", #"{"Results":"x"}"#])
    func aReportThatIsMissingOrBrokenIsBadOutput(report: String?) async throws {
        let d = try daemon(Scenario(archive: [tar()]))
        defer { d.stop() }
        let folder = try TempFolder()
        let scanner = FakeScanner()
        scanner.report = report
        #expect(failure(await runner(d, folder, scanner).scan(job()) { _ in }) == .badOutput)
        #expect(files(folder).isEmpty)
    }

    @Test func aTimedOutScannerIsATimeout() async throws {
        let d = try daemon(Scenario(archive: [tar()]))
        defer { d.stop() }
        let folder = try TempFolder()
        let scanner = FakeScanner()
        scanner.status = 15
        #expect(failure(await runner(d, folder, scanner).scan(job()) { _ in }) == .timeout)
    }

    @Test func aMissingProgramGivesStatus127AndMeansTheToolIsGone() async throws {
        let d = try daemon(Scenario(archive: [tar()]))
        defer { d.stop() }
        let folder = try TempFolder()
        let scanner = FakeScanner()
        scanner.status = 127
        scanner.log = "env: trivy: No such file or directory"
        #expect(failure(await runner(d, folder, scanner).scan(job()) { _ in }) == .toolMissing)
    }

    @Test func aScannerThatShellStoppedAtTheTimeLimitIsATimeout() async throws {
        let d = try daemon(Scenario(archive: [tar()]))
        defer { d.stop() }
        let folder = try TempFolder()
        let scanner = FakeScanner()
        scanner.status = 1
        scanner.log = "FATAL context canceled"
        scanner.timedOut = true
        #expect(failure(await runner(d, folder, scanner).scan(job()) { _ in }) == .timeout)
    }

    @Test func aScannerWithADatabaseThatCannotUpdateItNeedsAnUpdateNotAFirstScan() async throws {
        let d = try daemon(Scenario(archive: [tar()]))
        defer { d.stop() }
        let folder = try TempFolder()
        let scanner = FakeScanner()
        scanner.status = 1
        scanner.log = "the vulnerability database was built 9 days ago (max allowed age is 5 days)"
        #expect(failure(await runner(d, folder, scanner).scan(job(firstRun: false)) { _ in }) == .databaseUpdate)
    }

    @Test func anImageWithNoSizeIsRefusedBeforeTheExport() async throws {
        let d = try daemon(Scenario(size: 0, archive: [tar()]))
        defer { d.stop() }
        let folder = try TempFolder()
        let scanner = FakeScanner()
        let result = await runner(d, folder, scanner).scan(job()) { _ in }
        #expect(failure(result) == .exportFailed("it has no known size."))
        #expect(d.seen.count == 1)
        #expect(scanner.calls.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: folder.path + "/scan"))
    }

    @Test func aLinkInPlaceOfTheWorkFolderIsRefusedAndItsTargetKeepsItsMode() async throws {
        let d = try daemon(Scenario(archive: [tar()]))
        defer { d.stop() }
        let folder = try TempFolder()
        let target = folder.path + "/target"
        try FileManager.default.createDirectory(
            atPath: target, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o755])
        try FileManager.default.createSymbolicLink(atPath: folder.path + "/scan", withDestinationPath: target)
        let scanner = FakeScanner()
        let result = await runner(d, folder, scanner).scan(job()) { _ in }
        #expect(failure(result) == .exportFailed("ColimaBar cannot use its work folder."))
        #expect(scanner.calls.isEmpty)
        var st = stat()
        #expect(stat(target, &st) == 0)
        #expect(st.st_mode & 0o777 == 0o755)
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: target)) ?? []).isEmpty)
    }

    @Test func aFileInPlaceOfTheWorkFolderIsRefused() async throws {
        let d = try daemon(Scenario(archive: [tar()]))
        defer { d.stop() }
        let folder = try TempFolder()
        try Data("x".utf8).write(to: URL(fileURLWithPath: folder.path + "/scan"))
        let result = await runner(d, folder, FakeScanner()).scan(job()) { _ in }
        #expect(failure(result) == .exportFailed("ColimaBar cannot use its work folder."))
    }

    @Test func aFailedExportNeverStartsTheScanner() async throws {
        let d = try daemon(Scenario(getStatus: 500))
        defer { d.stop() }
        let folder = try TempFolder()
        let scanner = FakeScanner()
        let result = await runner(d, folder, scanner).scan(job()) { _ in }
        #expect(failure(result) == .exportFailed("Docker cannot save the images (HTTP 500)."))
        #expect(scanner.calls.isEmpty)
        #expect(files(folder).isEmpty)
    }

    @Test func anImageThatIsGoneNeverStartsTheExport() async throws {
        let d = try daemon(Scenario(inspectStatus: 404))
        defer { d.stop() }
        let folder = try TempFolder()
        let scanner = FakeScanner()
        let result = await runner(d, folder, scanner).scan(job()) { _ in }
        #expect(failure(result) == .exportFailed("the image is gone."))
        #expect(d.seen.count == 1)
        #expect(scanner.calls.isEmpty)
    }

    @Test func tooLittleFreeSpaceStopsBeforeTheExport() async throws {
        let d = try daemon(Scenario(size: 10 * Int(ByteFormat.bytesPerGiB), archive: [tar()]))
        defer { d.stop() }
        let folder = try TempFolder()
        let scanner = FakeScanner()
        let result = await runner(d, folder, scanner, free: 5 * ByteFormat.bytesPerGiB).scan(job()) { _ in }
        #expect(failure(result) == .lowDisk(needed: ImageScanRules.neededSpace(imageSize: 10 * ByteFormat.bytesPerGiB)))
        #expect(d.seen.count == 1)
        #expect(scanner.calls.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: folder.path + "/scan"))
    }

    @Test func anExportBeyondTwiceTheImageSizeStops() async throws {
        let d = try daemon(Scenario(size: 100, archive: [tar()]))
        defer { d.stop() }
        let folder = try TempFolder()
        let scanner = FakeScanner()
        let result = await runner(d, folder, scanner).scan(job()) { _ in }
        #expect(failure(result) == .exportFailed("the file is larger than expected."))
        #expect(scanner.calls.isEmpty)
        #expect(files(folder).isEmpty)
    }

    @Test func anExportThatSendsNoByteStops() async throws {
        let d = try daemon(Scenario(archive: [tar().prefix(2000)], holdOpen: true))
        defer { d.stop() }
        let folder = try TempFolder()
        let scanner = FakeScanner()
        let result = await runner(d, folder, scanner, stall: 0.3).scan(job()) { _ in }
        guard case .exportFailed(let reason) = failure(result) else {
            Issue.record("a stalled export passed")
            return
        }
        #expect(reason.hasPrefix("Docker sent no data"))
        #expect(scanner.calls.isEmpty)
        #expect(files(folder).isEmpty)
    }

    // MARK: Cancel

    @Test func aCancelDuringTheExportLeavesNoFile() async throws {
        let d = try daemon(Scenario(archive: [tar().prefix(2000)], holdOpen: true))
        defer { d.stop() }
        let folder = try TempFolder()
        let scanner = FakeScanner()
        let runner = runner(d, folder, scanner)
        let progressed = Box(false)
        let task = Task {
            await runner.scan(job()) { phase in
                if case .exporting(let bytes, _) = phase, bytes > 0 { progressed.mutate { $0 = true } }
            }
        }
        #expect(await waitUntil { progressed.value })
        runner.cancel()
        task.cancel()
        #expect(failure(await task.value) == .cancelled)
        #expect(scanner.calls.isEmpty)
        #expect(files(folder).isEmpty)
    }

    @Test func aCancelDuringTheScanStopsTheScannerAndLeavesNoFile() async throws {
        let d = try daemon(Scenario(archive: [tar()]))
        defer { d.stop() }
        let folder = try TempFolder()
        let scanner = FakeScanner()
        scanner.hold = true
        let runner = runner(d, folder, scanner)
        let task = Task { await runner.scan(job()) { _ in } }
        #expect(await waitUntil { scanner.calls.count == 1 })
        runner.cancel()
        task.cancel()
        #expect(failure(await task.value) == .cancelled)
        #expect(files(folder).isEmpty)
    }
}
