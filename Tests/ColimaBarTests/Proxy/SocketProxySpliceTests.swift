import Darwin
import Foundation
import Testing
import os

@testable import ColimaBar

@Suite(.serialized) struct SocketProxySpliceTests {
    // New short paths for each test, so suites that run in parallel never share a socket.
    let upstream = TestSocketPath.unique()
    let stable = TestSocketPath.unique()

    @Test func splicesToRunningDaemon() throws {
        let daemon = FakeDaemon(path: upstream)
        try daemon.start()
        defer { daemon.stop() }
        let p = SocketProxy(upstream: upstream, path: stable)
        p.start()
        defer {
            p.stop()
            unlink(stable)
        }

        let resp = roundTrip(stable, "GET /v1.54/containers/json HTTP/1.1\r\nHost: docker\r\n\r\n")
        #expect(resp.hasSuffix("hello"))
        #expect(daemon.seen == ["GET /v1.54/containers/json HTTP/1.1"])
    }

    @Test func answersPingWhileStoppedThenWakesOnRealRequest() throws {
        unlink(upstream)
        let daemon = FakeDaemon(path: upstream)
        let p = SocketProxy(upstream: upstream, path: stable)
        p.apiVersion = "1.54"
        let woke = Counter()
        p.wake = {
            woke.add()
            try? daemon.start()  // "Colima" comes up
            return true
        }
        p.start()
        defer {
            p.stop()
            daemon.stop()
            unlink(stable)
        }

        // docker's preflight ping must not boot the VM...
        let ping = roundTrip(stable, "HEAD /_ping HTTP/1.1\r\nHost: docker\r\n\r\n", until: "\r\n\r\n")
        #expect(ping.hasPrefix("HTTP/1.1 200 OK"))
        #expect(woke.value == 0)

        // ...but a real request on the same connection does, and goes through.
        let resp = roundTrip(
            stable,
            "HEAD /_ping HTTP/1.1\r\nHost: docker\r\n\r\n"
                + "POST /v1.54/containers/create HTTP/1.1\r\nHost: docker\r\nContent-Length: 0\r\n\r\n")
        #expect(resp.hasSuffix("hello"))
        #expect(woke.value == 1)
        #expect(daemon.seen == ["POST /v1.54/containers/create HTTP/1.1"])
    }

    @Test func failedWakeReturns503() throws {
        unlink(upstream)
        let p = SocketProxy(upstream: upstream, path: stable)
        p.wake = { false }
        p.start()
        defer {
            p.stop()
            unlink(stable)
        }
        let resp = roundTrip(stable, "GET /v1.54/containers/json HTTP/1.1\r\nHost: docker\r\n\r\n")
        #expect(resp.hasPrefix("HTTP/1.1 503"))
        #expect(resp.contains("could not start Colima"))
    }

    @Test func stopLeavesSymlinkToColima() throws {
        let p = SocketProxy(upstream: upstream, path: stable)
        p.start()
        p.stop()
        defer { unlink(stable) }
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: stable)) == upstream)
    }

    @Test func linkStableReplacesSocketWithSymlink() throws {
        let px = SocketProxy(upstream: upstream, path: stable)
        let fd = try UnixSocket.listen(stable)
        close(fd)
        px.linkStable(to: upstream)
        defer { unlink(stable) }
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: stable)) == upstream)
        #expect(!FileManager.default.fileExists(atPath: stable + ".lnk"))
    }

    @Test func requestsWaitWhileAWakeIsInProgress() throws {
        // While wake() runs, even with the upstream socket accepting, a new
        // request must not be spliced straight through (the daemon may be
        // restarting). It goes through after wake() reports ready.
        let daemon = FakeDaemon(path: upstream)
        let px = SocketProxy(upstream: upstream, path: stable)
        px.apiVersion = "1.54"
        let release = DispatchSemaphore(value: 0)
        let woke = Counter()
        px.wake = {
            try? daemon.start()  // socket accepts from here on
            woke.add()
            await withCheckedContinuation { c in
                DispatchQueue.global().async {
                    release.wait()
                    c.resume()
                }
            }
            return true
        }
        px.start()
        defer {
            px.stop()
            daemon.stop()
            unlink(stable)
        }

        let first = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            _ = roundTrip(stable, "GET /v1.54/containers/json HTTP/1.1\r\nHost: d\r\n\r\n")
            first.signal()
        }
        #expect(waitUntil { woke.value == 1 }, "the first request did not start a wake")
        let second = DispatchSemaphore(value: 0)
        let secondReply = OSAllocatedUnfairLock(initialState: "")
        DispatchQueue.global().async {
            let reply = roundTrip(stable, "GET /v1.54/info HTTP/1.1\r\nHost: d\r\n\r\n")
            secondReply.withLock { $0 = reply }
            second.signal()
        }
        // Nothing signals that the proxy holds the second request, so give it
        // time to reach the daemon if it were spliced too early.
        Thread.sleep(forTimeInterval: 0.5)
        #expect(!daemon.seen.contains { $0.contains("/info") }, "request reached the daemon before wake finished")
        release.signal()
        #expect(first.wait(timeout: .now() + 5) == .success)
        #expect(second.wait(timeout: .now() + 5) == .success)
        #expect(secondReply.withLock { $0 }.contains("hello"))
    }
}
