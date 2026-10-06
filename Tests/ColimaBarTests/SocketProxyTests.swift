import Darwin
import Foundation
import Testing

@testable import ColimaBar

@Suite struct PipelinedRequestTests {
    private func last(_ s: String) -> String {
        let bytes = Array(s.utf8)
        return bytes.withUnsafeBytes { SocketProxy.lastRequestLine($0) }
    }

    private func length(_ s: String) -> Int? {
        Array(s.utf8).withUnsafeBytes { SocketProxy.bodyLength($0) }
    }

    @Test func rawRequestLineMatchesTheArrayForm() {
        for s in ["POST /build HTTP/1.1\r\n", "GET /_ping HTTP/1.1", "Dockerfile\0", "", "GET x", "{\"a\":1}"] {
            let bytes = Array(s.utf8)
            let raw = bytes.withUnsafeBytes { SocketProxy.requestLine($0) }
            #expect(raw == SocketProxy.requestLine(bytes, bytes.count), "\(s.debugDescription)")
        }
    }

    @Test func lastRequestInTheChunkDecides() {
        let pull = "POST /v1.54/images/create?fromImage=alpine HTTP/1.1\r\nHost: d\r\nContent-Length: 0\r\n\r\n"
        let poll = "GET /v1.54/containers/json HTTP/1.1\r\nHost: d\r\n\r\n"
        #expect(last(pull + poll) == "GET /v1.54/containers/json HTTP/1.1")
        #expect(!SocketProxy.isWork(last(pull + poll)))
        #expect(SocketProxy.isWork(last(poll + pull)))
        // No Content-Length: no body, so the next request starts right after the head.
        #expect(last("POST /images/create HTTP/1.1\r\nHost: d\r\n\r\n" + poll) == "GET /v1.54/containers/json HTTP/1.1")
    }

    @Test func bodiesAreSkippedNotParsed() {
        let fake = "GET /x HTTP/1.1\r\n\r\n"
        let body = "\r\n\r\n" + fake
        // A body that looks like a request is skipped by its Content-Length.
        let withBody = "POST /build HTTP/1.1\r\ncontent-length: \(body.utf8.count)\r\n\r\n" + body
        #expect(last(withBody) == "POST /build HTTP/1.1")
        #expect(last(withBody + "GET /info HTTP/1.1\r\n\r\n") == "GET /info HTTP/1.1")
        // A chunked body stops the scan: the bytes after the head are body.
        #expect(last("POST /build HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n" + fake) == "POST /build HTTP/1.1")
        // A cut head or body bytes stop it too.
        #expect(last("POST /build HTTP/1.1\r\nHost: d\r\n\r\nDockerfile\0" + fake) == "POST /build HTTP/1.1")
        #expect(last("POST /build HTTP/1.1\r\nContent-Len") == "POST /build HTTP/1.1")
        #expect(last("POST /build HTTP/1.1\r\nContent-Length: 99999\r\n\r\n" + fake) == "POST /build HTTP/1.1")
        #expect(last("Dockerfile\0" + fake) == "")
    }

    @Test func bodyLengthReadsTheHead() {
        #expect(length("POST / HTTP/1.1\r\nHost: d\r\n\r\n") == 0)
        #expect(length("POST / HTTP/1.1\r\nContent-Length: 12\r\n\r\n") == 12)
        #expect(length("POST / HTTP/1.1\r\nCONTENT-LENGTH:7\r\n\r\n") == 7)
        #expect(length("POST / HTTP/1.1\r\ntransfer-encoding: chunked\r\n\r\n") == nil)
        #expect(length("POST / HTTP/1.1\r\nContent-Length: -1\r\n\r\n") == nil)
        #expect(length("POST / HTTP/1.1\r\nContent-Length: 99999999999999999999\r\n\r\n") == nil)
        #expect(length("POST / HTTP/1.1\r\nX-Content-Length: 5\r\n\r\n") == 0)
    }
}

@Suite(.serialized) struct PipelinedProxyTests {
    // sun_path is ~104 bytes, so keep test sockets short.
    let upstream = "/tmp/cb3-up-\(getpid()).sock"
    let stable = "/tmp/cb3-px-\(getpid()).sock"

    /// An upstream that reads forever and never answers: a daemon at work.
    private func busyUpstream() throws -> Int32 {
        let lfd = try UnixSocket.listen(upstream)
        Thread.detachNewThread {
            let c = accept(lfd, nil, nil)
            guard c >= 0 else { return }
            var buf = [UInt8](repeating: 0, count: 4096)
            while read(c, &buf, buf.count) > 0 {}
            close(c)
        }
        return lfd
    }

    private func send(_ chunks: [String]) throws -> Int {
        let lfd = try busyUpstream()
        let px = SocketProxy(upstream: upstream, path: stable)
        px.start()
        defer {
            px.stop()
            close(lfd)
            unlink(upstream)
            unlink(stable)
        }
        let fd = try #require(UnixSocket.connect(stable, timeout: 5))
        defer { close(fd) }
        for c in chunks {
            _ = UnixSocket.writeAll(fd, Data(c.utf8))  // one write: one read on the proxy side
            Thread.sleep(forTimeInterval: 0.3)
        }
        return px.activeTransfers()
    }

    private let pull = "POST /v1.54/images/create?fromImage=alpine HTTP/1.1\r\nHost: d\r\nContent-Length: 0\r\n\r\n"
    private let poll = "GET /v1.54/containers/json HTTP/1.1\r\nHost: d\r\n\r\n"

    @Test func pullThenPollInTheSameReadIsNotWork() throws {
        // First read of the connection (serve's fast path).
        #expect(try send([pull + poll]) == 0)
    }

    @Test func pullThenPollInALaterReadIsNotWork() throws {
        // A later read on the keep-alive connection (copy's classify).
        #expect(try send(["HEAD /_ping HTTP/1.1\r\nHost: d\r\n\r\n", pull + poll]) == 0)
    }

    @Test func pollThenPullInTheSameReadIsWork() throws {
        #expect(try send(["HEAD /_ping HTTP/1.1\r\nHost: d\r\n\r\n", poll + pull]) == 1)
    }
}
