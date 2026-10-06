import Darwin
import Foundation
import Testing

@testable import ColimaBar

/// Accepts one connection and reads the request head. Then it stays silent
/// for `silence` seconds and watches for EOF: a proxy that drops the client
/// half-closes its side, and the read gives 0. Then it answers and closes.
final class SilentDaemon: @unchecked Sendable {
    let path: String
    private let lock = NSLock()
    private var fd: Int32 = -1
    private var eof: Bool?

    init(path: String) { self.path = path }

    /// nil until the silence is over.
    var sawEOF: Bool? { lock.withLock { eof } }

    func start(silence: Int) throws {
        let lfd = try UnixSocket.listen(path)
        lock.withLock { fd = lfd }
        Thread.detachNewThread { [self] in
            let c = accept(lfd, nil, nil)
            guard c >= 0 else { return }
            defer { close(c) }
            UnixSocket.configure(c, timeout: 0)  // no SIGPIPE if the proxy hung up
            var buf = [UInt8](repeating: 0, count: 4096)
            var data = Data()
            while data.range(of: Data("\r\n\r\n".utf8)) == nil {
                let n = read(c, &buf, buf.count)
                if n <= 0 { return }
                data.append(buf, count: n)
            }
            UnixSocket.setTimeout(c, silence)
            let n = read(c, &buf, buf.count)
            lock.withLock { eof = n == 0 }
            _ = UnixSocket.writeAll(
                c, Data("HTTP/1.1 200 OK\r\nContent-Length: 4\r\nConnection: close\r\n\r\nlate".utf8))
        }
    }

    func stop() {
        let lfd = lock.withLock { fd }
        if lfd >= 0 { close(lfd) }
        unlink(path)
    }
}

@Suite(.serialized) struct Round2ProxyTests {
    // sun_path is ~104 bytes, so keep test sockets short.
    let upstream = "/tmp/cb2-up-\(getpid()).sock"
    let stable = "/tmp/cb2-px-\(getpid()).sock"

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

    @Test func pollAfterPullOnTheSameConnectionStopsCounting() throws {
        // A pooled client (docker-java) pulls once, then polls on the same
        // keep-alive connection. The poll must let auto-stop run.
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
        _ = UnixSocket.writeAll(fd, Data("POST /v1.54/images/create?fromImage=alpine HTTP/1.1\r\nHost: d\r\n\r\n".utf8))
        Thread.sleep(forTimeInterval: 0.3)
        #expect(px.activeTransfers() == 1)
        _ = UnixSocket.writeAll(fd, Data("GET /v1.54/containers/json HTTP/1.1\r\nHost: d\r\n\r\n".utf8))
        Thread.sleep(forTimeInterval: 0.3)
        #expect(px.activeTransfers() == 0)
        _ = UnixSocket.writeAll(fd, Data("POST /v1.54/images/create?fromImage=redis HTTP/1.1\r\nHost: d\r\n\r\n".utf8))
        Thread.sleep(forTimeInterval: 0.3)
        #expect(px.activeTransfers() == 1)
    }

    @Test func buildContextChunkKeepsTheBuildCounted() throws {
        // A build context tar can start with "Dockerfile". It is body, not
        // a new request, so the build still counts.
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
        _ = UnixSocket.writeAll(
            fd, Data("POST /v1.54/build?t=app HTTP/1.1\r\nHost: d\r\nContent-Type: application/x-tar\r\n\r\n".utf8))
        Thread.sleep(forTimeInterval: 0.3)
        #expect(px.activeTransfers() == 1)
        _ = UnixSocket.writeAll(fd, Data("Dockerfile\0\0\0\0000000644 GET /x HTTP/1.1".utf8))
        Thread.sleep(forTimeInterval: 0.3)
        #expect(px.activeTransfers() == 1)
    }

    @Test func silentClientIsClosedWhileVMIsUp() throws {
        let lfd = try busyUpstream()
        let px = SocketProxy(upstream: upstream, path: stable)
        px.idleTimeout = 1
        px.start()
        defer {
            px.stop()
            close(lfd)
            unlink(upstream)
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
        let px = SocketProxy(upstream: upstream, path: stable)
        px.idleTimeout = 1
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
        let px = SocketProxy(upstream: upstream, path: stable)
        px.idleTimeout = 1
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

@Suite struct RequestLineTests {
    @Test func onlyRealRequestsStartALine() {
        func line(_ s: String) -> String { SocketProxy.requestLine(Array(s.utf8), s.utf8.count) }
        #expect(line("GET /v1.54/containers/json HTTP/1.1\r\n") == "GET /v1.54/containers/json HTTP/1.1")
        #expect(line("OPTIONS /x HTTP/1.1\r\n") == "OPTIONS /x HTTP/1.1")
        #expect(line("Dockerfile\0\0\0") == "")
        #expect(line("PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n") == "")  // BuildKit's HTTP/2 preface
        #expect(line("GETX /a HTTP/1.1") == "")
        #expect(line("GET") == "")
    }

    @Test func logTargetDropsTheQuery() {
        let t = SocketProxy.logTarget(#"POST /v1.54/build?buildargs={"TOKEN":"s3cret"} HTTP/1.1"#)
        #expect(t == "POST /v1.54/build")
        #expect(SocketProxy.logTarget("GET /v1.54/containers/json HTTP/1.1") == "GET /v1.54/containers/json")
        #expect(SocketProxy.logTarget("") == "")
    }
}

@Suite struct DockerHostWhitespaceTests {
    @Test func whitespaceAloneSeparatesKeyAndValue() {
        #expect(Routing.dockerHostValue("docker.host tcp://remote:2375") == "tcp://remote:2375")
        #expect(Routing.dockerHostValue("docker.host\ttcp://remote:2375") == "tcp://remote:2375")
        #expect(Routing.dockerHostValue("  docker.host   unix:///tmp/a.sock\r") == "unix:///tmp/a.sock")
    }

    @Test func whitespaceThenSeparatorStillWorks() {
        #expect(Routing.dockerHostValue("docker.host   =  tcp://remote:2375") == "tcp://remote:2375")
        #expect(Routing.dockerHostValue("docker.host  :tcp://remote:2375") == "tcp://remote:2375")
    }

    @Test func otherKeysDoNotMatch() {
        #expect(Routing.dockerHostValue("docker.hostname tcp://remote:2375") == nil)
        #expect(Routing.dockerHostValue("docker.hostname=foo") == nil)
        #expect(Routing.dockerHostValue("docker.host") == nil)
        #expect(Routing.dockerHostValue("# docker.host tcp://remote:2375") == nil)
    }
}

@Suite struct RelaunchDecisionTests {
    @Test func restartsOnlyWhenTheBundleOnDiskChanged() {
        #expect(AppDelegate.restart(running: "0.3.0", onDisk: "0.3.0", isAgent: true) == .none)
        #expect(AppDelegate.restart(running: "0.3.0", onDisk: nil, isAgent: false) == .none)
        #expect(AppDelegate.restart(running: "0.3.0", onDisk: "0.4.0", isAgent: true) == .agent)
        #expect(AppDelegate.restart(running: "0.3.0", onDisk: "0.4.0", isAgent: false) == .manual)
        #expect(AppDelegate.restart(running: "0.4.0", onDisk: "0.3.0", isAgent: false) == .manual)  // downgrade
    }

    @Test func newerInstalledCopyTakesOver() {
        #expect(AppDelegate.takesOver(mine: "0.4.0", other: "0.3.0", installed: true))
        #expect(!AppDelegate.takesOver(mine: "0.4.0", other: "0.3.0", installed: false))  // DMG, Downloads
        #expect(!AppDelegate.takesOver(mine: "0.3.0", other: "0.3.0", installed: true))  // same version: reopen
        #expect(!AppDelegate.takesOver(mine: "0.3.0", other: "0.4.0", installed: true))
        #expect(!AppDelegate.takesOver(mine: "0.4.0", other: nil, installed: true))
        #expect(!AppDelegate.takesOver(mine: "dev", other: "0.3.0", installed: true))
    }

    @Test func installedPaths() {
        #expect(LoginItem.isInstalled("/Applications/ColimaBar.app"))
        #expect(LoginItem.isInstalled("\(Paths.home)/Applications/ColimaBar.app"))
        #expect(!LoginItem.isInstalled("/Volumes/ColimaBar/ColimaBar.app"))
        #expect(!LoginItem.isInstalled("/private/var/folders/x/AppTranslocation/Y/d/ColimaBar.app"))
    }

    @Test func revealRequestCountsFor60Seconds() {
        let now = 1_000_000.0
        #expect(AppDelegate.revealRequestIsFresh(now - 5, now: now))
        #expect(!AppDelegate.revealRequestIsFresh(now - 60, now: now))
        #expect(!AppDelegate.revealRequestIsFresh(now - 3600, now: now))
        #expect(!AppDelegate.revealRequestIsFresh(now + 30, now: now))  // clock went back
        #expect(!AppDelegate.revealRequestIsFresh(nil, now: now))
    }
}
