import Foundation

/// The image scan. After a click, ColimaBar exports one image from the Colima
/// socket of the running VM to a private tar file, runs Trivy or Grype on that
/// file and shows the report. The scanner gets no docker socket and pulls no
/// image. The files are deleted when the scan ends. A debug run exports no
/// image and runs no scanner.
extension ColimaModel {
    // MARK: - Scanners

    /// The scanner that a scan uses: the user's pick if it exists, else the
    /// other one if it exists, else nil.
    var activeScanner: ImageScanner? {
        scannersAvailable.contains(imageScanTool) ? imageScanTool : scannersAvailable.first
    }

    /// The setting row shows: Trivy or Grype is on the search path.
    var showsImageScan: Bool { !scannersAvailable.isEmpty }

    /// The scanner picker shows: both exist.
    var showsScannerPicker: Bool { scannersAvailable.count > 1 }

    /// The menu items and badges show: the setting is on and a scanner exists.
    var imageScanOn: Bool { imageScanEnabled && activeScanner != nil }

    /// Looks for the scanners on the search path. A fixture keeps its own list.
    func refreshScanners() {
        guard !scanFixtureLoaded else { return }
        setScanners(ImageScanner.allCases.filter { scannerLocator($0.binary) != nil })
    }

    nonisolated static func databaseOnDisk(_ tool: ImageScanner) -> Bool {
        let fm = FileManager.default
        return tool.hasDatabase(
            env: ProcessInfo.processInfo.environment, home: Paths.home,
            children: { (try? fm.contentsOfDirectory(atPath: $0)) ?? [] }, exists: fm.fileExists(atPath:))
    }

    // MARK: - Reports

    static func scanKey(profile: String, imageID: String) -> String { "\(profile)/\(imageID)" }

    /// The finished scan of an image of the selected profile, or nil.
    func imageScanReport(forImageID id: String) -> ImageScanReport? {
        Self.scanReport(in: imageScanReports, profile: profile, imageID: id)
    }

    /// The report of an image in one profile. A report of another profile
    /// stays hidden until the user selects that profile again.
    static func scanReport(in reports: [String: ImageScanReport], profile: String, imageID id: String)
        -> ImageScanReport?
    {
        ImageScanRules.normalizedID(id).flatMap { reports[scanKey(profile: profile, imageID: $0)] }
    }

    /// The scan that runs now or ran last, if it is about this image.
    func imageScanState(forImageID id: String) -> ImageScanState? {
        guard let state = imageScanState, state.profile == profile,
            ImageScanRules.normalizedID(id) == state.imageID
        else { return nil }
        return state
    }

    // MARK: - Run

    /// Starts a scan of the image `imageID` (an ID with or without `sha256:`).
    /// `name` is what the user saw. It does nothing if the scan may not run.
    func startImageScan(imageID: String, name: String) {
        guard canScanImages, let tool = activeScanner, let id = ImageScanRules.normalizedID(imageID) else { return }
        let p = profile
        let firstRun = !scanHasDatabase(tool)
        imageScanToken += 1
        let token = imageScanToken
        let state = ImageScanState(
            profile: p, imageID: id, imageName: name, tool: tool, phase: .exporting(bytes: 0, total: 0))
        setImageScan(state: state)
        holdAction(p)
        imageScanHold = p
        let runner = ImageScanRunner(api: api, dir: scanDir, run: scanRun, freeSpace: scanFreeSpace)
        imageScanRunner = runner
        log.notice("image scan started with \(tool.rawValue, privacy: .public)")
        imageScanTask = Task { [self, scanRun, scanOnline] in
            let online = await scanOnline()
            // A scanner without a database and without internet cannot work: say it before the export.
            guard online || !firstRun else {
                finishImageScan(.failure(.noDatabase), state: state, token: token)
                return
            }
            let version = await scannerVersion(tool, run: scanRun)
            let job = ImageScanRunner.Job(
                imageID: id, name: name, scanner: tool, version: version, offline: !online, firstRun: firstRun)
            let result = await runner.scan(job) { phase in
                Task { @MainActor in self.imageScanProgress(phase, token: token) }
            }
            finishImageScan(result, state: state, token: token)
        }
    }

    /// Stops the scan that runs now. The page then shows "cancelled".
    func cancelImageScan() {
        imageScanRunner?.cancel()
        imageScanTask?.cancel()
    }

    /// Scans an image again, under the name of its last scan or report. It
    /// does nothing if that scan runs now or if no scan of the image is known.
    func scanAgain(imageID id: String) {
        let state = imageScanState(forImageID: id)
        guard state?.isRunning != true,
            let name = state?.imageName ?? imageScanReport(forImageID: id)?.imageName,
            let normal = ImageScanRules.normalizedID(id)
        else { return }
        startImageScan(imageID: normal, name: name)
    }

    /// The quit of the app: stops the scan, ends the scanner process and
    /// deletes the files now. A quit does not wait for the task of the scan.
    func stopImageScanForQuit() {
        cancelImageScan()
        imageScanRunner?.removeFiles()
    }

    /// Forgets the scan that runs now and its late result. `dropReports` also
    /// forgets the finished scans.
    func resetImageScan(dropReports: Bool) {
        imageScanToken += 1
        cancelImageScan()
        imageScanRunner = nil
        imageScanTask = nil
        releaseScanHold()
        setImageScan(state: nil)
        if dropReports { setImageScan(reports: [:]) }
    }

    private func releaseScanHold() {
        guard let p = imageScanHold else { return }
        imageScanHold = nil
        releaseAction(p)
    }

    /// The runner reports. An export report after the start of the scanner is late: it counts for nothing.
    private func imageScanProgress(_ phase: ImageScanState.Phase, token: Int) {
        guard token == imageScanToken, var state = imageScanState, state.isRunning else { return }
        switch (state.phase, phase) {
        case (.exporting, .exporting), (.exporting, .scanning): state.phase = phase
        default: return
        }
        if case .scanning = phase { releaseScanHold() }
        setImageScan(state: state)
    }

    private func finishImageScan(_ result: Result<ImageScanReport, ImageScanError>, state: ImageScanState, token: Int) {
        guard token == imageScanToken else { return }
        releaseScanHold()
        imageScanRunner = nil
        imageScanTask = nil
        var done = state
        switch result {
        case .success(let report):
            done.phase = .done(report)
            setImageScan(
                reports: imageScanReports.merging([Self.scanKey(profile: state.profile, imageID: state.imageID): report]
                ) { $1 })
            log.notice("image scan done: \(report.findings.count, privacy: .public) findings")
        case .failure(let error):
            done.phase = .failed(error)
            log.error("image scan failed: \(error.kind, privacy: .public)")
            if ImageScanRules.mayNotify(error, pageVisible: imageScanOnScreen && visibleCount > 0) {
                notify("Scan of \(state.imageName) failed: \(error.message)")
            }
        }
        setImageScan(state: done)
    }

    /// The version of a scanner, read once in this launch. Nil if it gives none.
    private func scannerVersion(_ tool: ImageScanner, run: ImageScanRunner.Run) async -> String? {
        if let known = scannerVersions[tool] { return known }
        let result = await run(tool.versionArguments, tool.environment(offline: false), 10)
        guard result.ok, let version = tool.version(from: result.out) else { return nil }
        scannerVersions[tool] = version
        return version
    }

    // MARK: - Leftovers

    /// Removes the files of a scan that an earlier run left (a crash, a kill).
    func removeScanLeftovers() {
        guard !isDebug else { return }
        try? FileManager.default.removeItem(atPath: scanDir)
    }

    // MARK: - Debug fixture

    /// Debug runs only: shows the reports of `COLIMABAR_SCAN_FIXTURE` for the
    /// images whose reference matches, and turns the setting on in memory. It
    /// exports no image and runs no scanner. Returns false in a normal run,
    /// or when the data is not a fixture.
    @discardableResult
    func loadImageScanFixture(_ data: Data) -> Bool {
        guard isDebug, let fixture = try? JSONDecoder().decode(ImageScanFixture.self, from: data) else { return false }
        scanFixture = fixture
        scanFixtureLoaded = true
        setScanners(fixture.scanners)
        imageScanTool = fixture.scanner
        imageScanEnabled = true
        applyImageScanFixture()
        return true
    }

    /// Gives the images in the list the reports of the fixture. Every refresh
    /// of the image list calls it, so a new list keeps its reports.
    func applyImageScanFixture() {
        guard isDebug, let fixture = scanFixture else { return }
        var reports: [String: ImageScanReport] = [:]
        for row in images {
            guard let raw = fixture.reports[row.ref], let id = ImageScanRules.normalizedID(row.imageID) else {
                continue
            }
            reports[Self.scanKey(profile: profile, imageID: id)] = ImageScanReport(
                tool: fixture.scanner, toolVersion: raw.version, date: Date().addingTimeInterval(-180), imageID: id,
                imageName: row.ref, findings: fixture.findings(of: raw))
        }
        if Set(reports.keys) != Set(imageScanReports.keys) { setImageScan(reports: reports) }
    }
}
