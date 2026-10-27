import Darwin
import Foundation

/// One image scan: export the image to a private tar file, run the scanner on
/// that file, read its report and delete both files. The export goes through
/// the Colima socket of one profile (`api`), so it never starts the VM. The
/// scanner gets no docker socket, so it cannot start the VM and cannot pull
/// the image from a registry.
///
/// One scan at a time uses a runner. `cancel()` can come from any thread. The
/// task that calls `scan` must also be cancelled to stop the scanner process.
/// `@unchecked Sendable`: `lock` guards every mutable property.
final class ImageScanRunner: @unchecked Sendable {
    /// How the runner starts the scanner: the arguments, the extra
    /// environment and a time limit in seconds. A test passes a fake.
    typealias Run = @Sendable (_ args: [String], _ env: [String: String], _ timeout: TimeInterval) async -> Shell.Result

    /// The system runner. It joins stdout and stderr, which become the log
    /// of a failed scan. It refuses in a test process, so no test reaches a real scanner.
    static let system: Run = { args, env, timeout in
        guard !TestProcess.isRunning else { return Shell.Result(status: -1, out: "no scanner in a test") }
        return await Shell.run(args, timeout: timeout, extraEnv: env, includeStderr: true, cancellable: true)
    }

    /// What to scan and how.
    struct Job: Sendable {
        /// The image ID without `sha256:`.
        let imageID: String
        let name: String
        let scanner: ImageScanner
        let version: String?
        /// The Mac has no internet.
        let offline: Bool
        /// The scanner has no database on disk yet.
        let firstRun: Bool
    }

    private let api: DockerAPI
    private let dir: String
    private let run: Run
    private let freeSpace: @Sendable () -> Int64?
    private let stall: TimeInterval
    private let archive: ImageArchiveRunner
    private let lock = NSLock()
    private var cancelled = false
    private var stopReason: ImageScanError?
    /// The files of the scan that runs now.
    private var files: [String] = []

    /// `dir` is the work folder. `freeSpace` gives the free bytes of its disk, or nil. `stall` is the
    /// seconds without a byte after which the export stops.
    init(
        api: DockerAPI, dir: String, run: @escaping Run, freeSpace: @escaping @Sendable () -> Int64?,
        stall: TimeInterval = ImageScanRules.exportStall
    ) {
        self.api = api
        self.dir = dir
        self.run = run
        self.freeSpace = freeSpace
        self.stall = stall
        archive = ImageArchiveRunner(api: api)
    }

    func cancel() {
        lock.withLock { cancelled = true }
        archive.cancel()
    }

    /// Deletes the files of the scan that runs now. The quit of the app calls
    /// it, because a task that the quit stops cannot clean up. It is safe to call twice.
    func removeFiles() {
        let paths = lock.withLock { () -> [String] in
            defer { files = [] }
            return files
        }
        for path in paths { unlink(path) }
    }

    private var isCancelled: Bool { lock.withLock { cancelled } || Task.isCancelled }

    /// Runs the scan. `onPhase` gets the export progress and the start of the
    /// scanner, on any thread. The files are gone when it returns.
    func scan(_ job: Job, onPhase: @escaping @Sendable (ImageScanState.Phase) -> Void) async
        -> Result<ImageScanReport, ImageScanError>
    {
        guard !isCancelled else { return .failure(.cancelled) }
        let info: (id: String, size: Int64)
        switch await inspect(job.imageID) {
        case .success(let value): info = value
        case .failure(let error): return .failure(error)
        }
        // Without a size, the byte cap and the check of the free space do nothing.
        guard info.size > 0 else { return .failure(.exportFailed("it has no known size.")) }
        if let free = freeSpace(), !ImageScanRules.hasSpace(free: free, imageSize: info.size) {
            return .failure(.lowDisk(needed: ImageScanRules.neededSpace(imageSize: info.size)))
        }
        guard prepareFolder() else { return .failure(.exportFailed("ColimaBar cannot use its work folder.")) }
        let name = "\(ImageScanRules.shortID(job.imageID))-\(UUID().uuidString.prefix(8))"
        let tar = "\(dir)/\(name).tar"
        let output = "\(dir)/\(name).json"
        lock.withLock { files = [PrivateFileWriter.tempPath(for: tar), tar, output] }
        defer { removeFiles() }
        onPhase(.exporting(bytes: 0, total: info.size))
        if let error = await export(id: info.id, size: info.size, to: tar, onPhase: onPhase) {
            return .failure(error)
        }
        guard !isCancelled else { return .failure(.cancelled) }
        onPhase(.scanning(firstRun: job.firstRun))
        let args = job.scanner.arguments(
            input: tar, output: output, layout: ImageArchiveLayout.detect(path: tar), offline: job.offline)
        let result = await run(args, job.scanner.environment(offline: job.offline), ImageScanRules.scanTimeout)
        guard !isCancelled else { return .failure(.cancelled) }
        guard result.ok else {
            return .failure(
                ImageScanError.classify(
                    status: result.status, log: result.out, timedOut: result.timedOut, hadDatabase: !job.firstRun))
        }
        guard let findings = Self.readReport(at: output, with: job.scanner) else { return .failure(.badOutput) }
        return .success(
            ImageScanReport(
                tool: job.scanner, toolVersion: job.version, date: Date(), imageID: job.imageID,
                imageName: job.name, findings: findings))
    }

    // MARK: - Steps

    /// `GET /images/ID/json`: the full ID and the size.
    private func inspect(_ id: String) async -> Result<(id: String, size: Int64), ImageScanError> {
        guard let reply = await api.get("/images/\(ImageArchiveRunner.pathEncoded(id))/json") else {
            return .failure(.exportFailed("Docker did not answer."))
        }
        if reply.status == 404 { return .failure(.exportFailed("the image is gone.")) }
        guard reply.ok else { return .failure(.exportFailed("HTTP \(reply.status)")) }
        let object = try? JSONSerialization.jsonObject(with: reply.body) as? [String: Any]
        let full = (object?["Id"] as? String).flatMap(ImageScanRules.normalizedID) ?? id
        let size = (object?["Size"] as? NSNumber)?.int64Value ?? 0
        return .success((full, max(0, size)))
    }

    /// Makes sure that the work folder is a real folder of this user with
    /// mode 0700. It refuses a link, a file and a folder of another user, so
    /// a link cannot send the export to another place or change another folder.
    private func prepareFolder() -> Bool {
        var st = stat()
        if lstat(dir, &st) == 0 {
            guard (st.st_mode & S_IFMT) == S_IFDIR, st.st_uid == getuid() else { return false }
            return chmod(dir, 0o700) == 0
        }
        let parent = (dir as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(
            atPath: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return mkdir(dir, 0o700) == 0
    }

    /// Ends the export with `reason`. The first reason wins.
    private func stop(because reason: ImageScanError) {
        lock.withLock { if stopReason == nil { stopReason = reason } }
        archive.cancel()
    }

    /// Saves the image to `tar`. Nil means that the file is complete.
    private func export(
        id: String, size: Int64, to tar: String, onPhase: @escaping @Sendable (ImageScanState.Phase) -> Void
    ) async -> ImageScanError? {
        let watch = ExportWatch(cap: ImageScanRules.byteCap(imageSize: size))
        let watchdog = Task { [self, stall] in
            let step = Duration.seconds(min(1, stall / 4))
            while !Task.isCancelled {
                try? await Task.sleep(for: step)
                guard !Task.isCancelled, watch.isStalled(after: stall) else { continue }
                stop(because: .exportFailed("Docker sent no data for \(Int(stall)) seconds."))
                return
            }
        }
        let result = await archive.save(refs: ["sha256:\(id)"], to: tar) { [self] bytes in
            onPhase(.exporting(bytes: bytes, total: size))
            if watch.record(bytes) == .overCap { stop(because: .exportFailed("the file is larger than expected.")) }
        }
        watchdog.cancel()
        switch result {
        case .success: return nil
        case .failure(let failure):
            if let reason = lock.withLock({ stopReason }) { return reason }
            if failure.cancelled { return .cancelled }
            if failure.isDiskFull { return .diskFull }
            return .export(failure.reason)
        }
    }

    /// The free bytes of the disk that holds `path`. If the folder is missing, the
    /// nearest folder that exists answers. Nil if the system gives no value.
    static func freeSpace(near path: String) -> Int64? {
        var url = URL(fileURLWithPath: path)
        while !FileManager.default.fileExists(atPath: url.path), url.path != "/" { url.deleteLastPathComponent() }
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    /// The findings in the report file, or nil if the file is too large, missing or not a report.
    static func readReport(at path: String, with scanner: ImageScanner) -> [ImageScanFinding]? {
        var st = stat()
        guard stat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, Int(st.st_size) <= ImageScanRules.maxReportBytes,
            let data = FileManager.default.contents(atPath: path)
        else { return nil }
        return scanner.parse(data)
    }
}

/// The bytes of an export and the time of the last one. The reader thread of
/// the stream writes it. `@unchecked Sendable`: `lock` guards every mutable
/// property.
private final class ExportWatch: @unchecked Sendable {
    enum Verdict { case ok, overCap }

    private let lock = NSLock()
    private let cap: Int64
    private var bytes: Int64 = 0
    private var lastChange = ContinuousClock.now

    init(cap: Int64) { self.cap = cap }

    func record(_ total: Int64) -> Verdict {
        lock.withLock {
            if total != bytes { lastChange = .now }
            bytes = total
            return cap > 0 && total > cap ? .overCap : .ok
        }
    }

    func isStalled(after seconds: TimeInterval) -> Bool {
        lock.withLock { ContinuousClock.now - lastChange >= .seconds(seconds) }
    }
}
