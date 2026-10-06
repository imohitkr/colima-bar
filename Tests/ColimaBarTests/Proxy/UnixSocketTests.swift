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
}
