import Darwin
import Foundation
import Testing

@testable import ColimaBar

@Suite(.serialized) struct SocketProxyWorkTrackingTests {
    // New short paths for each test, so suites that run in parallel never share a socket.
    let upstream = TestSocketPath.unique()
    let stable = TestSocketPath.unique()

    private let pull = "POST /v1.54/images/create?fromImage=alpine HTTP/1.1\r\nHost: d\r\nContent-Length: 0\r\n\r\n"
    private let poll = "GET /v1.54/containers/json HTTP/1.1\r\nHost: d\r\n\r\n"
    private let ping = "HEAD /_ping HTTP/1.1\r\nHost: d\r\n\r\n"

    /// Starts a proxy in front of a busy upstream and connects one client.
    /// `body` gets the proxy and a `send` function. `send` writes one chunk
    /// (one write: one read on the proxy side) and waits until the upstream
    /// has it. The proxy classifies a chunk before it forwards it.
    private func withConnection(_ body: (SocketProxy, (String) -> Void) throws -> Void) throws {
        let up = try BusyUpstream(path: upstream)
        let px = SocketProxy(upstream: upstream, path: stable)
        px.start()
        defer {
            px.stop()
            up.stop()
            unlink(stable)
        }
        let fd = try #require(UnixSocket.connect(stable, timeout: 5))
        defer { close(fd) }
        var sent = 0
        try body(px) { chunk in
            _ = UnixSocket.writeAll(fd, Data(chunk.utf8))
            sent += chunk.utf8.count
            #expect(waitUntil { up.received >= sent }, "the upstream did not get the chunk")
        }
    }

    private func activeTransfers(after chunks: [String]) throws -> Int {
        var count = -1
        try withConnection { px, send in
            for c in chunks { send(c) }
            count = px.activeTransfers()
        }
        return count
    }

    @Test func pullThenPollInTheSameReadIsNotWork() throws {
        // First read of the connection (serve's fast path).
        #expect(try activeTransfers(after: [pull + poll]) == 0)
    }

    @Test func pullThenPollInALaterReadIsNotWork() throws {
        // A later read on the keep-alive connection (copy's classify).
        #expect(try activeTransfers(after: [ping, pull + poll]) == 0)
    }

    @Test func pollThenPullInTheSameReadIsWork() throws {
        #expect(try activeTransfers(after: [ping, poll + pull]) == 1)
    }

    @Test func pollAfterPullOnTheSameConnectionStopsCounting() throws {
        // A pooled client (docker-java) pulls once, then polls on the same
        // keep-alive connection. The poll must let auto-stop run.
        try withConnection { px, send in
            send("POST /v1.54/images/create?fromImage=alpine HTTP/1.1\r\nHost: d\r\n\r\n")
            // The proxy records the connection just after it forwards the first chunk.
            #expect(waitUntil { px.activeTransfers() == 1 })
            send(poll)
            #expect(px.activeTransfers() == 0)
            send("POST /v1.54/images/create?fromImage=redis HTTP/1.1\r\nHost: d\r\n\r\n")
            #expect(px.activeTransfers() == 1)
        }
    }

    @Test func buildContextChunkKeepsTheBuildCounted() throws {
        // A build context tar can start with "Dockerfile". It is body, not
        // a new request, so the build still counts.
        try withConnection { px, send in
            send("POST /v1.54/build?t=app HTTP/1.1\r\nHost: d\r\nContent-Type: application/x-tar\r\n\r\n")
            #expect(waitUntil { px.activeTransfers() == 1 })
            send("Dockerfile\0\0\0\0000000644 GET /x HTTP/1.1")
            #expect(px.activeTransfers() == 1)
        }
    }

    @Test func activeTransfersCountsOnlyLongBusyConnections() {
        let px = SocketProxy(upstream: upstream, path: stable)
        #expect(px.activeTransfers() == 0)
        let now = Date()
        px.addConnection(work: true, lastIO: now.addingTimeInterval(-10 * 60))  // silent build step
        px.addConnection(work: true, lastIO: now.addingTimeInterval(-40 * 60))  // stalled
        px.addConnection(work: false, lastIO: now)  // poller
        #expect(px.activeTransfers(now: now, stall: 30 * 60) == 1)
        #expect(px.activeTransfers(now: now, stall: 60 * 60) == 2)
        #expect(px.activeTransfers(now: now, stall: 60) == 0)
    }

    @Test func pullAfterPingOnTheSameConnectionCounts() throws {
        // The docker CLI sends HEAD /_ping, then reuses the keep-alive
        // connection for the pull. The pull must keep the VM awake.
        try withConnection { px, send in
            send(ping)
            #expect(px.activeTransfers() == 0)
            send("POST /v1.54/images/create?fromImage=alpine HTTP/1.1\r\nHost: d\r\n\r\n")
            #expect(waitUntil { px.activeTransfers() == 1 })
        }
    }
}
