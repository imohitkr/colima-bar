import Darwin
import Foundation

/// A TCP listener on 127.0.0.1 with a port that the system picks. It stands
/// in for a forwarded port. The test never leaves the loopback interface.
/// The accept thread owns the listener descriptor and closes it, with the
/// connections that it holds. `stop()` asks it to stop and waits for it, so
/// the port refuses connections when `stop()` returns.
/// `@unchecked Sendable`: `lock` guards the state.
final class LoopbackListener: @unchecked Sendable {
    enum Behavior: Sendable {
        /// Accepts and says nothing, like a server that waits for a request.
        case quiet
        /// Accepts and closes at once, like a dead forward.
        case closesAtOnce
        /// Accepts and sends a few bytes, like a server with a banner.
        case greets
    }

    let port: Int
    private let state = State()

    /// What the accept thread and the test share. `lock` guards the fields.
    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var stopped = false
        var clients: [Int32] = []
        let finished = DispatchSemaphore(value: 0)
    }

    /// With `wildcard`, it listens on 0.0.0.0, like a container that publishes a port
    /// on all addresses. A test closes it at once with `stop()`.
    init(_ behavior: Behavior, wildcard: Bool = false) throws {
        let s = socket(AF_INET, SOCK_STREAM, 0)
        guard s >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = wildcard ? UInt32(INADDR_ANY).bigEndian : UInt32(INADDR_LOOPBACK).bigEndian
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        let flags = fcntl(s, F_GETFL)
        guard bound == 0, listen(s, 16) == 0, flags >= 0, fcntl(s, F_SETFL, flags | O_NONBLOCK) == 0 else {
            let code = POSIXErrorCode(rawValue: errno) ?? .EIO
            close(s)
            throw POSIXError(code)
        }
        var name = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &name) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(s, $0, &length) }
        }
        port = Int(UInt16(bigEndian: name.sin_port))
        let state = state
        Thread.detachNewThread {
            Self.acceptLoop(listener: s, behavior: behavior, state: state)
        }
    }

    /// Accepts until `stop()`. Then it closes the listener and every connection.
    private static func acceptLoop(listener: Int32, behavior: Behavior, state: State) {
        defer {
            let open = state.lock.withLock { () -> [Int32] in
                state.stopped = true
                defer { state.clients = [] }
                return state.clients
            }
            close(listener)
            for c in open { close(c) }
            state.finished.signal()
        }
        var p = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
        while !state.lock.withLock({ state.stopped }) {
            guard poll(&p, 1, 20) > 0 else { continue }
            let c = accept(listener, nil, nil)
            if c < 0 { continue }
            switch behavior {
            case .closesAtOnce:
                close(c)
            case .quiet, .greets:
                if behavior == .greets {
                    var one: Int32 = 1
                    setsockopt(c, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
                    _ = write(c, "hi", 2)
                }
                // A client that arrives after `stop()` is closed here, not kept.
                let late = state.lock.withLock { () -> Bool in
                    if state.stopped { return true }
                    state.clients.append(c)
                    return false
                }
                if late { close(c) }
            }
        }
    }

    /// How many connections the listener has accepted and still holds
    /// (not `closesAtOnce`).
    var acceptedCount: Int { state.lock.withLock { state.clients.count } }

    /// The bytes that the accepted connections have received so far.
    var receivedBytes: Int {
        var total = 0
        var buffer = [UInt8](repeating: 0, count: 256)
        state.lock.withLock {
            for c in state.clients {
                let n = recv(c, &buffer, buffer.count, MSG_DONTWAIT)
                if n > 0 { total += n }
            }
        }
        return total
    }

    /// Stops the accept thread and waits for it (at most about 20 ms). The
    /// thread closes the listener and the connections. The port then refuses connections.
    func stop() {
        let first = state.lock.withLock { () -> Bool in
            defer { state.stopped = true }
            return !state.stopped
        }
        if first { state.finished.wait() }
    }

    deinit { stop() }

    /// A port that nothing listens on: it was free a moment ago. It is below
    /// the ephemeral range (49152 and up), so a listener of a parallel test,
    /// which binds port 0, cannot get it before the probe.
    static func unusedPort() throws -> Int {
        for _ in 0..<50 {
            let port = Int.random(in: 20000..<49152)
            if isFree(port) { return port }
        }
        throw POSIXError(.EADDRINUSE)
    }

    private static func isFree(_ port: Int) -> Bool {
        let s = socket(AF_INET, SOCK_STREAM, 0)
        guard s >= 0 else { return false }
        defer { close(s) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(port).bigEndian
        addr.sin_addr.s_addr = UInt32(INADDR_LOOPBACK).bigEndian
        return withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }
}
