import Darwin
import Foundation

@testable import ColimaBar

/// A one-request-per-connection HTTP server on a unix socket, standing in for
/// the Docker daemon. By default it answers each request with "hello".
/// `@unchecked Sendable`: `lock` guards `requests` and `received`.
final class FakeDaemon: @unchecked Sendable {
    /// The status and body of the answer to a request line, for example
    /// "GET /containers/abc/json HTTP/1.0".
    typealias Reply = @Sendable (_ requestLine: String) -> (status: Int, body: Data)

    /// A request with its headers (lower-cased names) and its body.
    struct Request: Sendable {
        let line: String
        let headers: [String: String]
        let body: Data
    }

    /// An answer. With `chunks`, the daemon sends no `Content-Length`: it
    /// sends the head, then each chunk, then closes. With `holdOpen`, it keeps
    /// the connection open after the last chunk until the client closes it.
    struct Answer: Sendable {
        var status = 200
        var body = Data()
        var chunks: [Data]?
        var holdOpen = false
    }

    typealias Handler = @Sendable (Request) -> Answer

    let path: String
    private let loop: AcceptLoop
    private(set) var requests: [String] = []
    private var received: [Request] = []
    private let lock = NSLock()
    private let handler: Handler

    init(path: String, reply: @escaping Reply = { _ in (200, Data("hello".utf8)) }) {
        self.path = path
        self.loop = AcceptLoop(path: path)
        self.handler = { request in
            let (status, body) = reply(request.line)
            return Answer(status: status, body: body)
        }
    }

    init(path: String, handler: @escaping Handler) {
        self.path = path
        self.loop = AcceptLoop(path: path)
        self.handler = handler
    }

    func start() throws {
        try loop.start { [self] c in
            let request = readRequest(c)
            lock.withLock {
                requests.append(request.line)
                received.append(request)
            }
            let answer = handler(request)
            if answer.chunks == nil {
                let head =
                    "HTTP/1.1 \(answer.status) \(Self.reason(answer.status))\r\nContent-Length: \(answer.body.count)\r\nConnection: close\r\n\r\n"
                _ = UnixSocket.writeAll(c, Data(head.utf8) + answer.body)
                close(c)
            } else {
                // A stream can wait for the client: do not block the accept loop.
                Thread.detachNewThread { Self.stream(answer, to: c, loop: self.loop) }
            }
        }
    }

    /// Ends the accept loop and waits for its thread. The thread closes the listener.
    func stop() { loop.stop() }

    var seen: [String] { lock.withLock { requests } }
    /// The requests with their headers and bodies, in the order that they arrived.
    var seenRequests: [Request] { lock.withLock { received } }

    private func readRequest(_ c: Int32) -> Request {
        var buf = [UInt8](repeating: 0, count: 64 * 1024)
        var data = Data()
        let end = Data("\r\n\r\n".utf8)
        while data.range(of: end) == nil {
            let n = read(c, &buf, buf.count)
            if n <= 0 { break }
            data.append(buf, count: n)
        }
        guard let split = data.range(of: end) else {
            return Request(line: String(decoding: data, as: UTF8.self), headers: [:], body: Data())
        }
        let (_, headers) = DockerAPI.parseHead(data[..<split.lowerBound])
        let line =
            String(decoding: data[..<split.lowerBound], as: UTF8.self).components(separatedBy: "\r\n").first ?? ""
        var body = Data(data[split.upperBound...])
        let length = headers["content-length"].flatMap { Int($0) } ?? 0
        while body.count < length {
            let n = read(c, &buf, min(buf.count, length - body.count))
            if n <= 0 { break }
            body.append(buf, count: n)
        }
        return Request(line: line, headers: headers, body: body)
    }

    private static func stream(_ answer: Answer, to c: Int32, loop: AcceptLoop) {
        let head = "HTTP/1.1 \(answer.status) \(reason(answer.status))\r\nConnection: close\r\n\r\n"
        var ok = UnixSocket.writeAll(c, Data(head.utf8))
        for chunk in answer.chunks ?? [] where ok { ok = UnixSocket.writeAll(c, chunk) }
        if answer.holdOpen, ok {
            // Poll, so a stopped daemon ends the wait.
            var byte = [UInt8](repeating: 0, count: 1)
            while !loop.isStopped {
                var p = pollfd(fd: c, events: Int16(POLLIN), revents: 0)
                guard poll(&p, 1, 20) != 0 else { continue }
                if read(c, &byte, 1) <= 0 { break }
            }
        }
        close(c)
    }

    private static func reason(_ status: Int) -> String {
        switch status {
        case 200: "OK"
        case 201: "Created"
        case 204: "No Content"
        case 404: "Not Found"
        case 409: "Conflict"
        default: "Error"
        }
    }
}
