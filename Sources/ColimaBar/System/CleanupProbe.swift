import Foundation

/// The I/O of the Cleanup page. It only reads. It never starts the VM: the
/// log call needs a running VM and goes through `colima ssh` on the profile.
enum CleanupProbe {
    /// The result of a log check.
    enum LogCheck: Equatable, Sendable {
        /// The size of the json log file of each container, by full ID.
        case sizes([String: Int64])
        /// The listing failed (see `LogFileSizes.parse`). `detail` is the last
        /// line of its error output, or empty.
        case failed(detail: String)
        /// The calling Task was cancelled. The child had no time to answer.
        case cancelled
    }

    /// Lists the log files of the containers in the VM of the profile.
    static func logSizes(profile: String) async -> LogCheck {
        let r = await Shell.run(
            LogFileSizes.command(profile: profile), timeout: 15, includeStderr: true, cancellable: true)
        if Task.isCancelled { return .cancelled }
        if let sizes = LogFileSizes.parse(status: r.status, out: r.out) { return .sizes(sizes) }
        return .failed(detail: LogFileSizes.failureDetail(r.out))
    }

    /// The disk image files of the profile, measured off the main thread.
    static func diskImage(profile: String, limaDir: String = Paths.limaDir) async -> DiskImageSize? {
        await Task.detached {
            DiskImageSize.measure(DiskImageSize.candidates(limaDir: limaDir, profile: profile), stat: stat)
        }.value
    }

    /// The stat for `DiskImageSize.measure`: lstat, regular files only,
    /// `st_blocks` in blocks of 512 bytes.
    static func stat(_ path: String) -> (blocks: Int64, size: Int64)? {
        var st = Foundation.stat()
        guard lstat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { return nil }
        return (Int64(st.st_blocks), Int64(st.st_size))
    }
}
