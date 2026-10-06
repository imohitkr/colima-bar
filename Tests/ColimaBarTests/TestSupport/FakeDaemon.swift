import Darwin
import Foundation

@testable import ColimaBar

/// A one-request-per-connection HTTP server on a unix socket, standing in for
/// the Docker daemon.
final class FakeDaemon: @unchecked Sendable {
    let path: String
    private var fd: Int32 = -1
    private(set) var requests: [String] = []
    private let lock = NSLock()

    init(path: String) { self.path = path }

    func start() throws {
        fd = try UnixSocket.listen(path)
        let fd = self.fd
        Thread.detachNewThread { [self] in
            while true {
                let c = accept(fd, nil, nil)
                if c < 0 { return }
                var buf = [UInt8](repeating: 0, count: 4096)
                var data = Data()
                while data.range(of: Data("\r\n\r\n".utf8)) == nil {
                    let n = read(c, &buf, buf.count)
                    if n <= 0 { break }
                    data.append(buf, count: n)
                }
                let line = String(decoding: data, as: UTF8.self).components(separatedBy: "\r\n").first ?? ""
                lock.withLock { requests.append(line) }
                _ = UnixSocket.writeAll(
                    c, Data("HTTP/1.1 200 OK\r\nContent-Length: 5\r\nConnection: close\r\n\r\nhello".utf8))
                close(c)
            }
        }
    }

    func stop() {
        if fd >= 0 {
            close(fd)
            fd = -1
        }
        unlink(path)
    }

    var seen: [String] { lock.withLock { requests } }
}
