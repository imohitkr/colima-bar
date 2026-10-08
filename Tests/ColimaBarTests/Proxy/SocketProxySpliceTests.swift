import Darwin
import Foundation
import Testing

@testable import ColimaBar

@Suite(.serialized) struct SocketProxySpliceTests {
    // New short paths for each test, so suites that run in parallel never share a socket.
    let upstream = TestSocketPath.unique()
    let stable = TestSocketPath.unique()

    @Test func splicesToRunningDaemon() async throws {
        let daemon = FakeDaemon(path: upstream)
        try daemon.start()
        defer { daemon.stop() }
        let p = SocketProxy(upstream: upstream, path: stable)
        p.start()
        defer {
            p.stop()
            unlink(stable)
        }

        let resp = await roundTrip(stable, "GET /v1.54/containers/json HTTP/1.1\r\nHost: docker\r\n\r\n")
        #expect(resp.hasSuffix("hello"))
        #expect(daemon.seen == ["GET /v1.54/containers/json HTTP/1.1"])
    }

    @Test func answersPingWhileStoppedThenWakesOnRealRequest() async throws {
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
        let ping = await roundTrip(stable, "HEAD /_ping HTTP/1.1\r\nHost: docker\r\n\r\n", until: "\r\n\r\n")
        #expect(ping.hasPrefix("HTTP/1.1 200 OK"))
        #expect(woke.value == 0)

        // ...but a real request on the same connection does, and goes through.
        let resp = await roundTrip(
            stable,
            "HEAD /_ping HTTP/1.1\r\nHost: docker\r\n\r\n"
                + "POST /v1.54/containers/create HTTP/1.1\r\nHost: docker\r\nContent-Length: 0\r\n\r\n")
        #expect(resp.hasSuffix("hello"))
        #expect(woke.value == 1)
        #expect(daemon.seen == ["POST /v1.54/containers/create HTTP/1.1"])
    }

    @Test func failedWakeReturns503() async throws {
        unlink(upstream)
        let p = SocketProxy(upstream: upstream, path: stable)
        p.wake = { false }
        p.start()
        defer {
            p.stop()
            unlink(stable)
        }
        let resp = await roundTrip(stable, "GET /v1.54/containers/json HTTP/1.1\r\nHost: docker\r\n\r\n")
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

    @Test func aRemovedProxyNeverTakesTheClientsOfANewOne() async throws {
        // ProfileProxies.sync removes a proxy and starts another in one call,
        // so the new listener can get the fd number that was just freed.
        let otherUpstream = TestSocketPath.unique()
        let otherPath = TestSocketPath.unique()
        let old = FakeDaemon(path: upstream) { _ in (200, Data("old".utf8)) }
        let new = FakeDaemon(path: otherUpstream) { _ in (200, Data("new".utf8)) }
        try old.start()
        try new.start()
        defer {
            old.stop()
            new.stop()
        }
        for _ in 0..<50 {
            let a = SocketProxy(upstream: upstream, path: stable)
            a.start()
            a.remove()
            let b = SocketProxy(upstream: otherUpstream, path: otherPath)
            b.start()
            let resp = await roundTrip(otherPath, "GET /v1.54/containers/json HTTP/1.1\r\nHost: docker\r\n\r\n")
            b.remove()
            #expect(resp.hasSuffix("new"))
        }
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

    @Test func requestsWaitWhileAWakeIsInProgress() async throws {
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

        async let first = roundTrip(stable, "GET /v1.54/containers/json HTTP/1.1\r\nHost: d\r\n\r\n")
        #expect(await waitUntil { woke.value == 1 }, "the first request did not start a wake")
        async let second = roundTrip(stable, "GET /v1.54/info HTTP/1.1\r\nHost: d\r\n\r\n")
        // Both requests wait for the wake: the second one reached the proxy.
        #expect(await waitUntil { px.wakeWaiters == 2 }, "the second request did not wait for the wake")
        #expect(!daemon.seen.contains { $0.contains("/info") }, "request reached the daemon before wake finished")
        release.signal()
        #expect(await first.contains("hello"))
        #expect(await second.contains("hello"))
    }

    @Test func proxiesOfOneUpstreamWaitForTheSameWake() async throws {
        // The stable socket and the profile socket of the selected profile
        // have one upstream. A wake that one of them starts holds the other
        // one too, as ColimaModel.wakeForProxy does. Its requests wait for
        // the same wake and do not reach a daemon that is not ready yet.
        let daemon = FakeDaemon(path: upstream)
        let other = TestSocketPath.unique()
        let a = SocketProxy(upstream: upstream, path: stable)
        let b = SocketProxy(upstream: upstream, path: other)
        let release = DispatchSemaphore(value: 0)
        let woke = Counter()
        let wake = SharedWake {
            a.holdForWake(true)
            b.holdForWake(true)
            try? daemon.start()  // socket accepts from here on
            woke.add()
            await withCheckedContinuation { c in
                DispatchQueue.global().async {
                    release.wait()
                    c.resume()
                }
            }
            a.holdForWake(false)
            b.holdForWake(false)
            return true
        }
        a.wake = { await wake.run() }
        b.wake = { await wake.run() }
        a.start()
        b.start()
        defer {
            a.stop()
            b.stop()
            daemon.stop()
            unlink(stable)
            unlink(other)
        }

        async let first = roundTrip(stable, "GET /v1.54/containers/json HTTP/1.1\r\nHost: d\r\n\r\n")
        #expect(await waitUntil { woke.value == 1 }, "the first request did not start a wake")
        async let second = roundTrip(other, "GET /v1.54/info HTTP/1.1\r\nHost: d\r\n\r\n")
        #expect(await waitUntil { wake.joined == 1 }, "the other proxy did not wait for the wake")
        #expect(!daemon.seen.contains { $0.contains("/info") }, "request reached the daemon before wake finished")
        release.signal()
        #expect(await first.contains("hello"))
        #expect(await second.contains("hello"))
        #expect(woke.value == 1)
    }
}

/// One wake at a time, like ColimaModel.wakeForProxy: a call during a wake
/// joins it. `joined` counts the calls that joined.
/// `@unchecked Sendable`: `lock` guards the mutable properties.
private final class SharedWake: @unchecked Sendable {
    private let lock = NSLock()
    private let body: @Sendable () async -> Bool
    private var task: Task<Bool, Never>?
    private var joins = 0

    init(_ body: @escaping @Sendable () async -> Bool) { self.body = body }

    var joined: Int { lock.withLock { joins } }

    func run() async -> Bool {
        let body = self.body
        let (t, isNew) = lock.withLock { () -> (Task<Bool, Never>, Bool) in
            if let t = task {
                joins += 1
                return (t, false)
            }
            let t = Task { await body() }
            task = t
            return (t, true)
        }
        let ok = await t.value
        if isNew { lock.withLock { task = nil } }
        return ok
    }
}
