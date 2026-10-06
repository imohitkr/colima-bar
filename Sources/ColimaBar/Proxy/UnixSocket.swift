import Darwin
import Foundation

/// Small POSIX helpers shared by the API client and the proxy.
enum UnixSocket {
    /// A socket call failed with this errno.
    enum Error: Swift.Error { case socket(Int32) }

    static func connect(_ path: String, timeout: Int = 0) -> Int32? {
        try? tryConnect(path, timeout: timeout).get()
    }

    /// Like connect, but a failure carries the errno, so the caller can tell
    /// "nothing listens there" (ENOENT, ECONNREFUSED) from "out of fds"
    /// (EMFILE, ENFILE).
    static func tryConnect(_ path: String, timeout: Int = 0) -> Result<Int32, Error> {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return .failure(.socket(errno)) }
        guard var addr = address(path) else {
            close(fd)
            return .failure(.socket(ENAMETOOLONG))
        }
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
            }
        }
        guard ok else {
            let err = errno
            close(fd)
            return .failure(.socket(err))
        }
        configure(fd, timeout: timeout)
        return .success(fd)
    }

    static func canConnect(_ path: String) -> Bool {
        guard let fd = connect(path) else { return false }
        close(fd)
        return true
    }

    /// Binds at `path.tmp`, then renames it over `path`. The rename is atomic,
    /// so clients never see a moment with no socket (or a dead one) at `path`.
    static func listen(_ path: String) throws -> Int32 {
        let tmp = path + ".tmp"
        unlink(tmp)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Error.socket(errno) }
        guard var addr = address(tmp) else {
            close(fd)
            throw Error.socket(ENAMETOOLONG)
        }
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
            }
        }
        guard bound, chmod(tmp, 0o600) == 0, Darwin.listen(fd, 128) == 0, rename(tmp, path) == 0 else {
            let err = errno
            close(fd)
            unlink(tmp)
            throw Error.socket(err)
        }
        return fd
    }

    /// Creates the socket's directory. ColimaBar's own cache directory is
    /// also made private to this user (0700); any other directory (tests) is
    /// left as it is.
    static func makePrivateDir(_ dir: String) {
        let own = (dir as NSString).standardizingPath == (Paths.cacheDir as NSString).standardizingPath
        try? FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true,
            attributes: own ? [.posixPermissions: 0o700] : nil)
        if own { chmod(dir, 0o700) }
    }

    static func configure(_ fd: Int32, timeout: Int) {
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        if timeout > 0 { setTimeout(fd, timeout) }
    }

    /// Sets the read and write timeout in seconds. 0 removes it.
    static func setTimeout(_ fd: Int32, _ seconds: Int) {
        var tv = timeval(tv_sec: seconds, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { raw -> Bool in
            var off = 0
            while off < raw.count {
                let n = write(fd, raw.baseAddress! + off, raw.count - off)
                if n <= 0 { return false }
                off += n
            }
            return true
        }
    }

    private static func address(_ path: String) -> sockaddr_un? {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        return addr
    }
}
