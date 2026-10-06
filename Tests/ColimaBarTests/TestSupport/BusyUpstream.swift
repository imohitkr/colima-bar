import Darwin
import Foundation

@testable import ColimaBar

/// An upstream daemon that accepts one connection, reads forever and never
/// answers: a daemon at work. It counts the bytes it receives, so a test can
/// wait until the proxy has forwarded a chunk.
final class BusyUpstream: @unchecked Sendable {
    let path: String
    private let fd: Int32
    private let lock = NSLock()
    private var bytes = 0

    init(path: String) throws {
        self.path = path
        let lfd = try UnixSocket.listen(path)
        fd = lfd
        Thread.detachNewThread { [self] in
            let c = accept(lfd, nil, nil)
            guard c >= 0 else { return }
            var buf = [UInt8](repeating: 0, count: 4096)
            while true {
                let n = read(c, &buf, buf.count)
                if n <= 0 { break }
                lock.withLock { bytes += n }
            }
            close(c)
        }
    }

    /// The number of bytes read so far.
    var received: Int { lock.withLock { bytes } }

    func stop() {
        close(fd)
        unlink(path)
    }
}
