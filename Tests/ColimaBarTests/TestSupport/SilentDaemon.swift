import Darwin
import Foundation

@testable import ColimaBar

/// Accepts one connection and reads the request head. Then it stays silent
/// for `silence` seconds and watches for EOF: a proxy that drops the client
/// half-closes its side, and the read gives 0. Then it answers and closes.
/// `@unchecked Sendable`: `lock` guards the mutable state that the server thread shares.
final class SilentDaemon: @unchecked Sendable {
    let path: String
    private let lock = NSLock()
    private var fd: Int32 = -1
    private var eof: Bool?

    init(path: String) { self.path = path }

    /// nil until the silence is over.
    var sawEOF: Bool? { lock.withLock { eof } }

    func start(silence: Int) throws {
        let lfd = try UnixSocket.listen(path)
        lock.withLock { fd = lfd }
        Thread.detachNewThread { [self] in
            let c = accept(lfd, nil, nil)
            guard c >= 0 else { return }
            defer { close(c) }
            UnixSocket.configure(c, timeout: 0)  // no SIGPIPE if the proxy hung up
            var buf = [UInt8](repeating: 0, count: 4096)
            var data = Data()
            while data.range(of: Data("\r\n\r\n".utf8)) == nil {
                let n = read(c, &buf, buf.count)
                if n <= 0 { return }
                data.append(buf, count: n)
            }
            UnixSocket.setTimeout(c, silence)
            let n = read(c, &buf, buf.count)
            lock.withLock { eof = n == 0 }
            _ = UnixSocket.writeAll(
                c, Data("HTTP/1.1 200 OK\r\nContent-Length: 4\r\nConnection: close\r\n\r\nlate".utf8))
        }
    }

    func stop() {
        let lfd = lock.withLock { fd }
        if lfd >= 0 { close(lfd) }
        unlink(path)
    }
}
