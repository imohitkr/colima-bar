import Darwin
import Foundation
import os

/// Checks if a TCP port answers on the Mac (127.0.0.1). It connects, waits
/// a short time and peeks at the socket. It never sends data, so the app
/// behind the port sees only an empty connection.
///
/// A dead forward often accepts the connection and then closes it at once.
/// Thus a connect alone is not enough: an end of stream right after the
/// connect means that nothing answers.
enum PortProbe {
    enum Result: Equatable, Sendable {
        /// Connected, and the peer sent data or stayed quiet.
        case open
        /// Connected, and the peer closed at once.
        case closed
        /// Nothing listens.
        case refused
        /// The connect did not finish in time.
        case timeout
        /// A local failure (a socket call failed). The port is not known to be broken.
        case error
    }

    private static let log = Logger(category: "network")

    /// How many ports `check(ports:)` probes at the same time.
    static let concurrency = 8

    /// Probes the ports, at most `concurrency` at a time, on dispatch
    /// threads, so the cooperative pool never blocks.
    static func check(ports: [Int], peekWait: TimeInterval = 0.5) async -> [Int: Result] {
        await withTaskGroup(of: (Int, Result).self) { group in
            var rest = ports[...]
            func add() {
                guard let port = rest.popFirst() else { return }
                group.addTask { (port, await check(port: port, peekWait: peekWait)) }
            }
            for _ in 0..<min(concurrency, ports.count) { add() }
            var out: [Int: Result] = [:]
            for await (port, result) in group {
                out[port] = result
                add()
            }
            return out
        }
    }

    /// True when something on this Mac accepts a connection on `port`, on
    /// 127.0.0.1 or on ::1 (`ipv6`). A connection that closes at once counts:
    /// a process listens there. The proxy of container domains uses it to
    /// skip a busy port before it binds.
    static func listens(port: Int, ipv6: Bool, timeout: TimeInterval) async -> Bool {
        await withCheckedContinuation { cont in
            Thread.detachNewThread {
                let r = checkSync(port: port, connectTimeout: timeout, peekWait: 0, ipv6: ipv6)
                cont.resume(returning: r == .open || r == .closed)
            }
        }
    }

    static func check(port: Int, connectTimeout: TimeInterval = 1, peekWait: TimeInterval = 0.5) async -> Result {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: checkSync(port: port, connectTimeout: connectTimeout, peekWait: peekWait))
            }
        }
    }

    /// The blocking probe. Call it off the main thread only.
    static func checkSync(
        port: Int, connectTimeout: TimeInterval = 1, peekWait: TimeInterval = 0.5, ipv6: Bool = false
    ) -> Result {
        guard (1...65535).contains(port) else { return .refused }
        let fd = socket(ipv6 ? AF_INET6 : AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            log.error("port probe: socket() failed, errno \(errno, privacy: .public)")
            return .error
        }
        defer { close(fd) }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else {
            log.error("port probe: fcntl() failed, errno \(errno, privacy: .public)")
            return .error
        }

        let rc: Int32
        if ipv6 {
            var addr = sockaddr_in6()
            addr.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            addr.sin6_family = sa_family_t(AF_INET6)
            addr.sin6_port = UInt16(port).bigEndian
            addr.sin6_addr = in6addr_loopback
            rc = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
                }
            }
        } else {
            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = UInt16(port).bigEndian
            addr.sin_addr.s_addr = UInt32(INADDR_LOOPBACK).bigEndian
            rc = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        if rc != 0 {
            guard errno == EINPROGRESS else { return connectFailure(errno) }
            let waited = wait(fd, events: Int16(POLLOUT), seconds: connectTimeout)
            if waited < 0 {
                log.error("port probe: poll() failed, errno \(errno, privacy: .public)")
                return .error
            }
            guard waited > 0 else { return .timeout }
            var error: Int32 = 0
            var length = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length) == 0 else {
                log.error("port probe: getsockopt() failed, errno \(errno, privacy: .public)")
                return .error
            }
            guard error == 0 else { return connectFailure(error) }
        }

        // Connected. A quiet peer is fine. An end of stream is a dead forward.
        let ready = wait(fd, events: Int16(POLLIN), seconds: peekWait)
        if ready < 0 {
            log.error("port probe: poll() failed, errno \(errno, privacy: .public)")
            return .error
        }
        guard ready > 0 else { return .open }
        var byte: UInt8 = 0
        let n = recv(fd, &byte, 1, MSG_PEEK)
        if n > 0 { return .open }
        if n == 0 { return .closed }
        return errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR ? .open : .closed
    }

    /// What a failed connect means. Only ECONNREFUSED says that nothing
    /// listens. A timeout or an unreachable host is `timeout`. Other errors
    /// are local, so they are `error`.
    static func connectFailure(_ code: Int32) -> Result {
        switch code {
        case ECONNREFUSED: return .refused
        case ETIMEDOUT, EHOSTUNREACH, ENETUNREACH, ECONNRESET, ECONNABORTED: return .timeout
        default:
            log.error("port probe: connect() failed, errno \(code, privacy: .public)")
            return .error
        }
    }

    /// Waits for `events` on `fd`. Returns the result of `poll`: more than 0
    /// if the descriptor is ready.
    private static func wait(_ fd: Int32, events: Int16, seconds: TimeInterval) -> Int32 {
        var p = pollfd(fd: fd, events: events, revents: 0)
        let end = Date().addingTimeInterval(seconds)
        while true {
            let ms = Int32(max(0, end.timeIntervalSinceNow) * 1000)
            let r = poll(&p, 1, ms)
            if r < 0, errno == EINTR { continue }
            return r
        }
    }
}
