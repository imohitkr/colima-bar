import Darwin
import Foundation

/// The status file that a normal run of the app writes for the `colimabar`
/// command (`Paths.appStatus`). It holds no secret: the PID, the version and
/// the auto-stop times. The mode is 0600 in the folder with mode 0700.
enum AppStatusFile {
    /// A status file is far smaller. A bigger file is not ours.
    static let maxBytes = 64 * 1024

    /// Writes the file: a new temporary file (`O_EXCL` and `O_NOFOLLOW`, so
    /// a link at that path is never followed), then `rename`. A reader never
    /// sees half a file.
    static func write(_ status: AppStatus, path: String = Paths.appStatus) throws {
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let temp = "\(path).\(getpid()).tmp"
        unlink(temp)
        let fd = open(temp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let data = status.encoded()
        var written = 0
        var failure: Int32 = 0
        data.withUnsafeBytes { raw in
            while written < data.count {
                let n = Darwin.write(fd, raw.baseAddress! + written, data.count - written)
                if n < 0 {
                    if errno == EINTR { continue }
                    failure = errno
                    return
                }
                written += n
            }
        }
        close(fd)
        if failure == 0, rename(temp, path) != 0 { failure = errno }
        if failure != 0 {
            unlink(temp)
            throw POSIXError(POSIXErrorCode(rawValue: failure) ?? .EIO)
        }
    }

    /// The status of the running app, or nil: no file, a file that is not
    /// ours, a file of an app that is gone (see `AppStatus.isStale`).
    static func read(
        path: String = Paths.appStatus, now: Date = Date(),
        startTime: (Int) -> Date? = { ProcessProbe.startTime(pid: $0) }
    ) -> AppStatus? {
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(),
            info.st_size <= maxBytes
        else { return nil }
        guard let data = try? FileHandle(fileDescriptor: fd, closeOnDealloc: false).readToEnd(),
            let status = AppStatus.decode(data)
        else { return nil }
        let mtime = Date(
            timeIntervalSince1970: Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1e9)
        guard !status.isStale(mtime: mtime, now: now, ownerStarted: startTime(status.pid)) else { return nil }
        return status
    }

    /// Removes the file if it holds `pid`. A copy that quits must not remove
    /// the file of another copy.
    static func removeIfOwned(by pid: Int = Int(getpid()), path: String = Paths.appStatus) {
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size <= maxBytes,
            let data = try? FileHandle(fileDescriptor: fd, closeOnDealloc: false).readToEnd(),
            AppStatus.decode(data)?.pid == pid
        else { return }
        unlink(path)
    }
}
