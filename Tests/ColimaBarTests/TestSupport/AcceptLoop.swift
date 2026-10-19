import Darwin
import Foundation

@testable import ColimaBar

/// Accepts connections of a unix socket on its own thread, for a fake server.
///
/// The thread owns the listening fd: it polls with a short timeout, ends when
/// `stop()` sets the flag, and closes the fd itself. So no thread is ever in
/// `accept` on an fd that another thread closed, and no other test can get
/// that fd number while this loop still uses it. `stop()` waits until the
/// thread has ended.
/// `@unchecked Sendable`: `lock` guards `stopped`.
final class AcceptLoop: @unchecked Sendable {
    let path: String
    private let lock = NSLock()
    private var stopped = false
    private let ended = DispatchSemaphore(value: 0)
    private var started = false

    init(path: String) { self.path = path }

    /// True after `stop()`. A handler can check it to end its own wait.
    var isStopped: Bool { lock.withLock { stopped } }

    /// Starts to listen. `onConnection` runs on the loop thread, and owns the
    /// fd it gets: it must close it, or hand it to a thread that does.
    func start(onConnection: @escaping @Sendable (Int32) -> Void) throws {
        let fd = try UnixSocket.listen(path)
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        started = true
        Thread.detachNewThread { [self] in
            while !isStopped {
                var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                guard poll(&p, 1, 20) > 0 else { continue }
                let c = accept(fd, nil, nil)
                if c < 0 { continue }
                _ = fcntl(c, F_SETFL, fcntl(c, F_GETFL) & ~O_NONBLOCK)  // BSD can inherit it
                UnixSocket.configure(c, timeout: 0)
                onConnection(c)
            }
            close(fd)
            ended.signal()
        }
    }

    /// Ends the loop, waits for its thread and removes the socket path.
    func stop() {
        let wasStopped = lock.withLock {
            defer { stopped = true }
            return stopped
        }
        if !wasStopped, started { _ = ended.wait(timeout: .now() + 5) }
        unlink(path)
    }
}
