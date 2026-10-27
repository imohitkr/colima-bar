import Darwin
import Foundation

/// Writes a file in chunks. The file has the mode 0600 from the first byte,
/// and `commit` makes it appear only when it is complete. An error or a
/// cancel leaves no file.
///
/// The bytes always go to `DEST.PID.tmp`. `commit` moves that file to `DEST`.
/// With `replace` (the save panel asked about a replace), it renames the file
/// over `DEST`: a file or a symlink at `DEST` goes away, and a symlink is
/// never followed. Without `replace`, `RENAME_EXCL` makes the move atomic and
/// refuses a file or a symlink that is at `DEST`, so nothing is ever replaced.
///
/// One thread at a time uses a writer.
final class PrivateFileWriter {
    private let destination: String
    private let temp: String
    private let replace: Bool
    private var fd: Int32
    private(set) var bytes: Int64 = 0

    /// The path of the file that holds the bytes until `commit`.
    static func tempPath(for destination: String) -> String { "\(destination).\(getpid()).tmp" }

    /// Throws a `POSIXError`: `EEXIST` if `DEST` exists and `replace` is false.
    init(destination: String, replace: Bool) throws {
        self.destination = destination
        self.replace = replace
        temp = Self.tempPath(for: destination)
        // Fail early, before ColimaBar reads the whole volume. `commit` checks again.
        var probe = stat()
        if !replace, lstat(destination, &probe) == 0 { throw POSIXError(.EEXIST) }
        // A temporary file of an earlier run, or a link that someone put there,
        // goes away first. `unlink` never follows a link.
        unlink(temp)
        fd = open(temp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    deinit { abort() }

    func write(_ data: Data) throws {
        guard fd >= 0 else { throw POSIXError(.EBADF) }
        try data.withUnsafeBytes { raw in
            var done = 0
            while done < raw.count {
                let n = Darwin.write(fd, raw.baseAddress! + done, raw.count - done)
                if n < 0 {
                    if errno == EINTR { continue }
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                done += n
            }
        }
        bytes += Int64(data.count)
    }

    /// Flushes the file to disk and puts it at its place. On an error it
    /// removes the file and throws.
    func commit() throws {
        guard fd >= 0 else { throw POSIXError(.EBADF) }
        if fsync(fd) != 0 {
            let code = errno
            abort()
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        let closed = close(fd)
        let closeError = errno
        fd = -1
        if closed != 0 {
            remove()
            throw POSIXError(POSIXErrorCode(rawValue: closeError) ?? .EIO)
        }
        let moved = replace ? rename(temp, destination) : renamex_np(temp, destination, UInt32(RENAME_EXCL))
        if moved != 0 {
            let code = errno
            unlink(temp)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
    }

    /// Closes the file and removes it. It does nothing after a `commit`.
    func abort() {
        guard fd >= 0 else { return }
        close(fd)
        fd = -1
        remove()
    }

    private func remove() { unlink(temp) }
}
