import Darwin
import Foundation
import Testing

@testable import ColimaBar

@Suite struct UnixSocketTests {
    // New short paths for each test, so suites that run in parallel never share a socket.
    let upstream = TestSocketPath.unique()
    let stable = TestSocketPath.unique()

    @Test func listenReplacesAStaleSocketAtomically() throws {
        // A leftover file at the path (crash) must not block listening.
        FileManager.default.createFile(atPath: stable, contents: Data("stale".utf8))
        let fd = try UnixSocket.listen(stable)
        defer {
            close(fd)
            unlink(stable)
        }
        var st = stat()
        #expect(lstat(stable, &st) == 0)
        #expect((st.st_mode & S_IFMT) == S_IFSOCK)
        #expect((st.st_mode & 0o777) == 0o600)
        #expect(!FileManager.default.fileExists(atPath: stable + ".tmp"))
    }

    @Test func connectErrnoTellsDownFromOtherErrors() {
        unlink(upstream)
        guard case .failure(.socket(let err)) = UnixSocket.tryConnect(upstream) else {
            Issue.record("connect to a missing path succeeded")
            return
        }
        #expect(err == ENOENT)
        #expect(SocketProxy.meansVMDown(ENOENT))
        #expect(SocketProxy.meansVMDown(ECONNREFUSED))
        #expect(!SocketProxy.meansVMDown(EMFILE))
        #expect(!SocketProxy.meansVMDown(ENFILE))
    }

    private func noSigPipe(_ fd: Int32) -> Bool {
        var value: Int32 = 0
        var size = socklen_t(MemoryLayout<Int32>.size)
        return getsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &value, &size) == 0 && value != 0
    }

    /// Without the option, the write to a closed peer would kill the test process.
    @Test func aWriteToAClosedPeerFailsWithEPIPEOnBothEnds() throws {
        let listener = try UnixSocket.listen(stable)
        defer {
            close(listener)
            unlink(stable)
        }
        #expect(noSigPipe(listener))
        guard case .success(let client) = UnixSocket.tryConnect(stable) else {
            Issue.record("connect failed")
            return
        }
        let served = accept(listener, nil, nil)
        #expect(served >= 0)
        defer { if served >= 0 { close(served) } }
        #expect(noSigPipe(client))
        #expect(noSigPipe(served))

        // The client leaves: the accepted socket (the proxy side) writes to nobody.
        close(client)
        let bytes = [UInt8](repeating: 1, count: 16)
        var result = write(served, bytes, bytes.count)
        if result >= 0 { result = write(served, bytes, bytes.count) }  // the first write can still pass
        #expect(result == -1 && errno == EPIPE)

        // The other way: the proxy side leaves, and the client writes.
        guard case .success(let client2) = UnixSocket.tryConnect(stable) else {
            Issue.record("connect failed")
            return
        }
        defer { close(client2) }
        let served2 = accept(listener, nil, nil)
        close(served2)
        var result2 = write(client2, bytes, bytes.count)
        if result2 >= 0 { result2 = write(client2, bytes, bytes.count) }
        #expect(result2 == -1 && errno == EPIPE)
    }
}
