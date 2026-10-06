import Darwin
import Foundation
import Testing
@testable import ColimaBar

@Suite(.serialized) struct ProxyLimitTests {
    // sun_path is ~104 bytes, so keep test sockets short.
    let upstream = "/tmp/cbl-up-\(getpid()).sock"
    let stable = "/tmp/cbl-px-\(getpid()).sock"

    @Test func outOfFdsAnswers503WithoutWake() throws {
        let p = SocketProxy(upstream: upstream, path: stable)
        let woke = Counter()
        p.wake = { woke.add(); return true }
        p.connectUpstream = { _ in .failure(.socket(EMFILE)) }
        p.start()
        defer { p.stop(); unlink(stable) }

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
        p.wake = { woke.add(); return false }
        p.start()
        defer { p.stop(); unlink(stable) }

        let resp = roundTrip(stable, "GET /v1.54/containers/json HTTP/1.1\r\nHost: docker\r\n\r\n")
        #expect(resp.hasPrefix("HTTP/1.1 503"))
        #expect(resp.contains("could not start Colima"))
        #expect(woke.value == 1)
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

    @Test func idleClientIsClosedWhileVMIsDown() throws {
        unlink(upstream)
        let p = SocketProxy(upstream: upstream, path: stable)
        p.idleTimeout = 1
        p.start()
        defer { p.stop(); unlink(stable) }

        let fd = try #require(UnixSocket.connect(stable, timeout: 10))
        defer { close(fd) }
        let started = Date()
        var buf = [UInt8](repeating: 0, count: 16)
        let n = read(fd, &buf, buf.count)   // send nothing: the proxy must hang up
        #expect(n == 0)
        #expect(Date().timeIntervalSince(started) < 5)
    }

    @Test func fileLimitRaisesButNeverLowers() {
        var before = rlimit()
        #expect(getrlimit(RLIMIT_NOFILE, &before) == 0)
        let cap = min(before.rlim_max, rlim_t(OPEN_MAX))

        // A lower target leaves the limit alone.
        #expect(FileLimit.raise(to: 1) == before.rlim_cur)

        let target = min(before.rlim_cur + 64, cap)
        let after = FileLimit.raise(to: target)
        var now = rlimit()
        #expect(getrlimit(RLIMIT_NOFILE, &now) == 0)
        #expect(now.rlim_cur == after)
        #expect(after >= before.rlim_cur)
        #expect(after >= target)
        #expect(after <= now.rlim_max)
    }

    @Test func plistRoundTripIsNotOutdated() throws {
        let exe = "/Applications/ColimaBar.app/Contents/MacOS/ColimaBar"
        let data = try PropertyListSerialization.data(fromPropertyList: LoginItem.plistContents(exe: exe),
                                                      format: .xml, options: 0)
        let read = try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        #expect(!LoginItem.plistIsOutdated(read, exe: exe))
        let limits = read["SoftResourceLimits"] as? [String: Any]
        #expect(limits?["NumberOfFiles"] as? Int == 8192)

        // A plist from an older version (no SoftResourceLimits) is outdated.
        var old = read
        old["SoftResourceLimits"] = nil
        #expect(LoginItem.plistIsOutdated(old, exe: exe))
    }
}
