import Darwin
import Foundation

@testable import ColimaBar

/// A one-request-per-connection HTTP server on a unix socket, standing in for
/// the Docker daemon. By default it answers each request with "hello".
/// `@unchecked Sendable`: `lock` guards `requests`; only the test thread touches `fd`.
final class FakeDaemon: @unchecked Sendable {
    /// The status and body of the answer to a request line, for example
    /// "GET /containers/abc/json HTTP/1.0".
    typealias Reply = @Sendable (_ requestLine: String) -> (status: Int, body: Data)

    let path: String
    private var fd: Int32 = -1
    private(set) var requests: [String] = []
    private let lock = NSLock()
    private let reply: Reply

    init(path: String, reply: @escaping Reply = { _ in (200, Data("hello".utf8)) }) {
        self.path = path
        self.reply = reply
    }

    func start() throws {
        fd = try UnixSocket.listen(path)
        let fd = self.fd
        Thread.detachNewThread { [self] in
            while true {
                let c = accept(fd, nil, nil)
                if c < 0 { return }
                UnixSocket.configure(c, timeout: 0)  // no SIGPIPE if the client hung up
                var buf = [UInt8](repeating: 0, count: 4096)
                var data = Data()
                while data.range(of: Data("\r\n\r\n".utf8)) == nil {
                    let n = read(c, &buf, buf.count)
                    if n <= 0 { break }
                    data.append(buf, count: n)
                }
                let line = String(decoding: data, as: UTF8.self).components(separatedBy: "\r\n").first ?? ""
                lock.withLock { requests.append(line) }
                let (status, body) = reply(line)
                let reason = status == 200 ? "OK" : "Error"
                let head = "HTTP/1.1 \(status) \(reason)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
                _ = UnixSocket.writeAll(c, Data(head.utf8) + body)
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
