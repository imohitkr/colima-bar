import Darwin
import Foundation
import Testing

@testable import ColimaBar

@Suite(.serialized) struct SocketProxyTimeoutTests {
    // New short paths for each test, so suites that run in parallel never share a socket.
    let upstream = TestSocketPath.unique()
    let stable = TestSocketPath.unique()

    @Test func outOfFdsAnswers503WithoutWake() throws {
        let p = SocketProxy(upstream: upstream, path: stable, connectUpstream: { _ in .failure(.socket(EMFILE)) })
        let woke = Counter()
        p.wake = {
            woke.add()
            return true
        }
        p.start()
        defer {
            p.stop()
            unlink(stable)
        }

        let started = Date()
        let resp = roundTrip(stable, "GET /v1.54/containers/json HTTP/1.1\r\nHost: docker\r\n\r\n")
        #expect(resp.hasPrefix("HTTP/1.1 503"))
        #expect(resp.contains("errno \(EMFILE)"))
        #expect(woke.value == 0)
        #expect(Date().timeIntervalSince(started) < 5)
    }

    @Test func missingSocketStillWakes() throws {
        unlink(upstream)
        let p = SocketProxy(upstream: upstream, path: stable)
        let woke = Counter()
        p.wake = {
            woke.add()
            return false
        }
        p.start()
        defer {
            p.stop()
            unlink(stable)
        }

        let resp = roundTrip(stable, "GET /v1.54/containers/json HTTP/1.1\r\nHost: docker\r\n\r\n")
        #expect(resp.hasPrefix("HTTP/1.1 503"))
        #expect(resp.contains("could not start Colima"))
        #expect(woke.value == 1)
    }

    @Test func idleClientIsClosedWhileVMIsDown() throws {
        unlink(upstream)
        let p = SocketProxy(upstream: upstream, path: stable, idleTimeout: 1)
        p.start()
        defer {
            p.stop()
            unlink(stable)
        }

        let fd = try #require(UnixSocket.connect(stable, timeout: 10))
        defer { close(fd) }
        let started = Date()
        var buf = [UInt8](repeating: 0, count: 16)
        let n = read(fd, &buf, buf.count)  // send nothing: the proxy must hang up
        #expect(n == 0)
        #expect(Date().timeIntervalSince(started) < 5)
    }

    @Test func silentClientIsClosedWhileVMIsUp() throws {
        let up = try BusyUpstream(path: upstream)
        let px = SocketProxy(upstream: upstream, path: stable, idleTimeout: 1)
        px.start()
        defer {
            px.stop()
            up.stop()
            unlink(stable)
        }

        let fd = try #require(UnixSocket.connect(stable, timeout: 10))
        defer { close(fd) }
        let started = Date()
        var buf = [UInt8](repeating: 0, count: 16)
        #expect(read(fd, &buf, buf.count) == 0)  // send nothing: the proxy must hang up
        #expect(Date().timeIntervalSince(started) < 5)
    }

    @Test func splicedStreamOutlivesIdleTimeout() throws {
        // VM up: the first read has a timeout, and splice() must remove it.
        let daemon = SilentDaemon(path: upstream)
        try daemon.start(silence: 3)
        let px = SocketProxy(upstream: upstream, path: stable, idleTimeout: 1)
        px.start()
        defer {
            px.stop()
            daemon.stop()
            unlink(stable)
        }

        let reply = roundTrip(stable, "GET /v1.54/containers/x/attach?stream=1 HTTP/1.1\r\nHost: d\r\n\r\n")
        #expect(reply.hasSuffix("late"))
        #expect(daemon.sawEOF == false, "the proxy dropped the client during a silent stream")
    }

    @Test func streamAfterWakeOutlivesIdleTimeout() throws {
        // VM down: the client waits with a timeout, then the wake splices it.
        unlink(upstream)
        let daemon = SilentDaemon(path: upstream)
        let px = SocketProxy(upstream: upstream, path: stable, idleTimeout: 1)
        px.wake = { (try? daemon.start(silence: 3)) != nil }
        px.start()
        defer {
            px.stop()
            daemon.stop()
            unlink(stable)
        }

        let reply = roundTrip(stable, "GET /v1.54/events HTTP/1.1\r\nHost: d\r\n\r\n")
        #expect(reply.hasSuffix("late"))
        #expect(daemon.sawEOF == false, "the proxy dropped the client during a silent stream")
    }

    @Test func oversizedRequestHeadGets431WithoutWake() throws {
        unlink(upstream)
        let px = SocketProxy(upstream: upstream, path: stable)
        let woke = Counter()
        px.wake = {
            woke.add()
            return true
        }
        px.start()
        defer {
            px.stop()
            unlink(stable)
        }

        let pad = String(repeating: "a", count: SocketProxy.maxHead + 2048)
        let reply = roundTrip(stable, "GET /v1.54/containers/json HTTP/1.1\r\nX-Pad: \(pad)\r\n")
        #expect(reply.hasPrefix("HTTP/1.1 431"))
        #expect(woke.value == 0)
    }

    @Test func headEndSplitAcrossReadsIsFound() throws {
        // "\r\n\r\n" arrives in two reads: the search must cover the seam.
        unlink(upstream)
        let px = SocketProxy(upstream: upstream, path: stable)
        px.apiVersion = "1.54"
        px.start()
        defer {
            px.stop()
            unlink(stable)
        }

        let fd = try #require(UnixSocket.connect(stable, timeout: 5))
        defer { close(fd) }
        _ = UnixSocket.writeAll(fd, Data("GET /_ping HTTP/1.1\r\nHost: d\r".utf8))
        Thread.sleep(forTimeInterval: 0.2)
        _ = UnixSocket.writeAll(fd, Data("\n\r\n".utf8))
        var buf = [UInt8](repeating: 0, count: 1024)
        let n = read(fd, &buf, buf.count)
        #expect(n > 0 && String(decoding: buf[0..<max(n, 0)], as: UTF8.self).hasPrefix("HTTP/1.1 200 OK"))
    }
}
