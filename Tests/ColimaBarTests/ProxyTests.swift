import Darwin
import Foundation
import Testing

@testable import ColimaBar

/// A one-request-per-connection HTTP server on a unix socket, standing in for
/// the Docker daemon.
final class FakeDaemon: @unchecked Sendable {
    let path: String
    private var fd: Int32 = -1
    private(set) var requests: [String] = []
    private let lock = NSLock()

    init(path: String) { self.path = path }

    func start() throws {
        fd = try UnixSocket.listen(path)
        let fd = self.fd
        Thread.detachNewThread { [self] in
            while true {
                let c = accept(fd, nil, nil)
                if c < 0 { return }
                var buf = [UInt8](repeating: 0, count: 4096)
                var data = Data()
                while data.range(of: Data("\r\n\r\n".utf8)) == nil {
                    let n = read(c, &buf, buf.count)
                    if n <= 0 { break }
                    data.append(buf, count: n)
                }
                let line = String(decoding: data, as: UTF8.self).components(separatedBy: "\r\n").first ?? ""
                lock.withLock { requests.append(line) }
                _ = UnixSocket.writeAll(
                    c, Data("HTTP/1.1 200 OK\r\nContent-Length: 5\r\nConnection: close\r\n\r\nhello".utf8))
                close(c)
            }
        }
    }

    func stop() {
        if fd >= 0 {
            close(fd)
            fd = -1
        }
        unlink(path)
    }

    var seen: [String] { lock.withLock { requests } }
}

/// Sends raw HTTP over a unix socket and returns everything read until close
/// or until `until` appears.
func roundTrip(_ path: String, _ request: String, until: String? = nil) -> String {
    guard let fd = UnixSocket.connect(path, timeout: 10) else { return "<no connect>" }
    defer { close(fd) }
    _ = UnixSocket.writeAll(fd, Data(request.utf8))
    var out = Data()
    var buf = [UInt8](repeating: 0, count: 4096)
    while true {
        if let until, String(decoding: out, as: UTF8.self).contains(until) { break }
        let n = read(fd, &buf, buf.count)
        if n <= 0 { break }
        out.append(buf, count: n)
    }
    return String(decoding: out, as: UTF8.self)
}

@Suite(.serialized) struct ProxyTests {
    // sun_path is ~104 bytes, so keep test sockets short.
    let upstream = "/tmp/cbt-up-\(getpid()).sock"
    let stable = "/tmp/cbt-px-\(getpid()).sock"

    @Test func pingReplyOnlyForPings() {
        let p = SocketProxy(upstream: upstream, path: stable)
        #expect(p.pingReply("HEAD /_ping HTTP/1.1") == nil)  // API version unknown yet
        p.apiVersion = "1.54"
        let head = String(decoding: p.pingReply("HEAD /_ping HTTP/1.1")!, as: UTF8.self)
        #expect(head.contains("Api-Version: 1.54"))
        #expect(!head.hasSuffix("OK"))
        #expect(String(decoding: p.pingReply("GET /v1.54/_ping HTTP/1.1")!, as: UTF8.self).hasSuffix("\r\n\r\nOK"))
        #expect(p.pingReply("GET /v1.54/containers/json HTTP/1.1") == nil)
        #expect(p.pingReply("POST /_ping HTTP/1.1") == nil)
        #expect(p.pingReply("GET /vX/_ping HTTP/1.1") == nil)
    }

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
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func add() { lock.withLock { n += 1 } }
    var value: Int { lock.withLock { n } }
}
