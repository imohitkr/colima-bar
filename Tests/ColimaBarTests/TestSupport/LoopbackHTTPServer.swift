import Darwin
import Foundation

/// A small HTTP server on 127.0.0.1 (or ::1) with a port that the system picks. It
/// stands in for a container that publishes a web port. Each connection has
/// its own thread. The test never leaves the loopback interface.
///
/// `.hello` answers each request with 200 and the body `<marker> <Host> <path>`,
/// and keeps the connection open. `.echo` answers the first head with 200 and
/// then sends back every byte that follows, like a WebSocket echo.
/// `stop()` waits for the accept thread. `@unchecked Sendable`: `state.lock`
/// guards the state.
final class LoopbackHTTPServer: @unchecked Sendable {
    enum Mode: Sendable {
        case hello
        case echo
    }

    let port: Int
    private let state = State()

    /// What the threads and the test share. `lock` guards the fields.
    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var stopped = false
        var clients: Set<Int32> = []
        var requests = 0
        var endsOfStream = 0
        let finished = DispatchSemaphore(value: 0)
        var isStopped: Bool { lock.withLock { stopped } }
    }

    /// With `ipv6`, the server listens on ::1 and not on 127.0.0.1.
    init(marker: String, mode: Mode = .hello, ipv6: Bool = false) throws {
        let s = socket(ipv6 ? AF_INET6 : AF_INET, SOCK_STREAM, 0)
        guard s >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var bound: Int32
        var chosen: UInt16 = 0
        if ipv6 {
            var addr = sockaddr_in6()
            addr.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            addr.sin6_family = sa_family_t(AF_INET6)
            addr.sin6_port = 0
            addr.sin6_addr = in6addr_loopback
            bound = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(s, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
                }
            }
        } else {
            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = 0
            addr.sin_addr.s_addr = UInt32(INADDR_LOOPBACK).bigEndian
            bound = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        let flags = fcntl(s, F_GETFL)
        guard bound == 0, listen(s, 16) == 0, flags >= 0, fcntl(s, F_SETFL, flags | O_NONBLOCK) == 0 else {
            let code = POSIXErrorCode(rawValue: errno) ?? .EIO
            close(s)
            throw POSIXError(code)
        }
        if ipv6 {
            var name = sockaddr_in6()
            var length = socklen_t(MemoryLayout<sockaddr_in6>.size)
            _ = withUnsafeMutablePointer(to: &name) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(s, $0, &length) }
            }
            chosen = UInt16(bigEndian: name.sin6_port)
        } else {
            var name = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            _ = withUnsafeMutablePointer(to: &name) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(s, $0, &length) }
            }
            chosen = UInt16(bigEndian: name.sin_port)
        }
        port = Int(chosen)
        let state = state
        Thread.detachNewThread { Self.acceptLoop(listener: s, marker: marker, mode: mode, state: state) }
    }

    /// The requests that the `.hello` mode answered.
    var requestCount: Int { state.lock.withLock { state.requests } }

    /// How many connections the server saw end (the client closed or half-closed).
    var endsOfStream: Int { state.lock.withLock { state.endsOfStream } }

    func stop() {
        let first = state.lock.withLock { () -> Bool in
            defer { state.stopped = true }
            return !state.stopped
        }
        if first { state.finished.wait() }
    }

    deinit { stop() }

    private static func acceptLoop(listener: Int32, marker: String, mode: Mode, state: State) {
        var p = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
        while !state.isStopped {
            guard poll(&p, 1, 20) > 0 else { continue }
            let c = accept(listener, nil, nil)
            if c < 0 { continue }
            var one: Int32 = 1
            setsockopt(c, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            // The accepted socket may inherit O_NONBLOCK. The reader polls, so either way works.
            state.lock.withLock { _ = state.clients.insert(c) }
            Thread.detachNewThread { serve(c, marker: marker, mode: mode, state: state) }
        }
        close(listener)
        // Wake the readers. Each thread closes its own descriptor.
        state.lock.withLock { for c in state.clients { shutdown(c, SHUT_RDWR) } }
        state.finished.signal()
    }

    private static func serve(_ fd: Int32, marker: String, mode: Mode, state: State) {
        defer {
            state.lock.withLock { _ = state.clients.remove(fd) }
            close(fd)
        }
        var buffer = Data()
        var echoing = false
        while let chunk = read(fd, state: state) {
            if chunk.isEmpty {
                state.lock.withLock { state.endsOfStream += 1 }
                return
            }
            if echoing {
                _ = write(fd, chunk)
                continue
            }
            buffer.append(chunk)
            while let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: buffer[buffer.startIndex..<end.lowerBound], as: UTF8.self)
                let rest = Data(buffer[end.upperBound...])
                buffer = rest
                if mode == .echo {
                    _ = write(fd, Data("HTTP/1.1 200 OK\r\nConnection: close\r\n\r\n".utf8))
                    echoing = true
                    if !buffer.isEmpty { _ = write(fd, buffer) }
                    buffer = Data()
                    break
                }
                let lines = head.components(separatedBy: "\r\n")
                let path = lines[0].split(separator: " ").dropFirst().first.map(String.init) ?? "?"
                let host =
                    lines.dropFirst().first { $0.lowercased().hasPrefix("host:") }
                    .map { String($0.dropFirst(5)).trimmingCharacters(in: .whitespaces) } ?? "?"
                let body = "\(marker) \(host) \(path)"
                let reply = "HTTP/1.1 200 OK\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"
                _ = write(fd, Data(reply.utf8))
                state.lock.withLock { state.requests += 1 }
            }
        }
    }

    /// The next bytes, an empty value at the end of the stream, or nil when the server stops.
    private static func read(_ fd: Int32, state: State) -> Data? {
        var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        var buf = [UInt8](repeating: 0, count: 16384)
        while !state.isStopped {
            guard poll(&p, 1, 20) > 0 else { continue }
            let n = recv(fd, &buf, buf.count, 0)
            if n < 0, errno == EAGAIN || errno == EINTR { continue }
            return n > 0 ? Data(buf[0..<n]) : Data()
        }
        return nil
    }

    @discardableResult
    private static func write(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { raw in
            var sent = 0
            while sent < raw.count {
                let n = Darwin.write(fd, raw.baseAddress! + sent, raw.count - sent)
                if n < 0, errno == EAGAIN || errno == EINTR { continue }
                if n <= 0 { return false }
                sent += n
            }
            return true
        }
    }
}
