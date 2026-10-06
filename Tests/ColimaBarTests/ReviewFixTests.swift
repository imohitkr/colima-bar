import Darwin
import Foundation
import Testing
@testable import ColimaBar

@Suite struct IdleMinutesTests {
    @Test func acceptsWholeMinutesInRange() {
        #expect(IdleMinutes.parse("5") == 5)
        #expect(IdleMinutes.parse(" 90 ") == 90)
        #expect(IdleMinutes.parse("1440") == 1440)
    }

    @Test func rejectsOutOfRangeAndNonNumbers() {
        #expect(IdleMinutes.parse("0") == nil)
        #expect(IdleMinutes.parse("1441") == nil)
        #expect(IdleMinutes.parse("-3") == nil)
        #expect(IdleMinutes.parse("1.5") == nil)
        #expect(IdleMinutes.parse("abc") == nil)
        #expect(IdleMinutes.parse("") == nil)
    }

    @Test func presetsKeepExistingChoicesAndAddFive() {
        #expect(IdleMinutes.presets == [5, 15, 30, 60])
    }
}

@Suite struct IconOtherProfileTests {
    @Test func staysVisibleWhileAnotherProfileRuns() {
        #expect(!ColimaModel.hidesIcon(enabled: true, revealed: false, state: .stopped, busy: false,
                                       dashboardOpen: false, otherProfileRunning: true))
    }
}

@Suite struct HTTPHeadTests {
    @Test func parsesStatusAndLowercasedHeaders() {
        let (status, headers) = DockerAPI.parseHead(Data("HTTP/1.1 404 Not Found\r\nApi-Version: 1.54\r\nContent-Type: application/json".utf8))
        #expect(status == 404)
        #expect(headers["api-version"] == "1.54")
        #expect(headers["content-type"] == "application/json")
    }
}

@Suite(.serialized) struct ProxyReviewTests {
    let upstream = "/tmp/cbr-up-\(getpid()).sock"
    let stable = "/tmp/cbr-px-\(getpid()).sock"

    @Test func listenReplacesAStaleSocketAtomically() throws {
        // A leftover file at the path (crash) must not block listening.
        FileManager.default.createFile(atPath: stable, contents: Data("stale".utf8))
        let fd = try UnixSocket.listen(stable)
        defer { close(fd); unlink(stable) }
        var st = stat()
        #expect(lstat(stable, &st) == 0)
        #expect((st.st_mode & S_IFMT) == S_IFSOCK)
        #expect((st.st_mode & 0o777) == 0o600)
        #expect(!FileManager.default.fileExists(atPath: stable + ".tmp"))
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
        px.wake = {
            try? daemon.start()               // socket accepts from here on
            await withCheckedContinuation { c in
                DispatchQueue.global().async { release.wait(); c.resume() }
            }
            return true
        }
        px.start()
        defer { px.stop(); daemon.stop(); unlink(stable) }

        let first = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            _ = roundTrip(stable, "GET /v1.54/containers/json HTTP/1.1\r\nHost: d\r\n\r\n")
            first.signal()
        }
        Thread.sleep(forTimeInterval: 0.5)      // wake is now in progress
        let second = DispatchSemaphore(value: 0)
        var secondReply = ""
        DispatchQueue.global().async {
            secondReply = roundTrip(stable, "GET /v1.54/info HTTP/1.1\r\nHost: d\r\n\r\n")
            second.signal()
        }
        Thread.sleep(forTimeInterval: 0.5)
        #expect(!daemon.seen.contains { $0.contains("/info") }, "request reached the daemon before wake finished")
        release.signal()
        #expect(first.wait(timeout: .now() + 5) == .success)
        #expect(second.wait(timeout: .now() + 5) == .success)
        #expect(secondReply.contains("hello"))
    }

    @Test func activeTransfersCountsOnlyLongBusyConnections() {
        let px = SocketProxy(upstream: upstream, path: stable)
        #expect(px.activeTransfers() == 0)
        let now = Date()
        px.addConnection(work: true, lastIO: now.addingTimeInterval(-10 * 60))    // silent build step
        px.addConnection(work: true, lastIO: now.addingTimeInterval(-40 * 60))    // stalled
        px.addConnection(work: false, lastIO: now)                                // poller
        #expect(px.activeTransfers(now: now, stall: 30 * 60) == 1)
        #expect(px.activeTransfers(now: now, stall: 60 * 60) == 2)
        #expect(px.activeTransfers(now: now, stall: 60) == 0)
    }

    @Test func pullAfterPingOnTheSameConnectionCounts() throws {
        // The docker CLI sends HEAD /_ping, then reuses the keep-alive
        // connection for the pull. The pull must keep the VM awake.
        let lfd = try UnixSocket.listen(upstream)
        Thread.detachNewThread {
            let c = accept(lfd, nil, nil)
            guard c >= 0 else { return }
            var buf = [UInt8](repeating: 0, count: 4096)
            while read(c, &buf, buf.count) > 0 {}   // a daemon that is still working
            close(c)
        }
        let px = SocketProxy(upstream: upstream, path: stable)
        px.start()
        defer { px.stop(); close(lfd); unlink(upstream); unlink(stable) }

        let fd = try #require(UnixSocket.connect(stable, timeout: 5))
        defer { close(fd) }
        _ = UnixSocket.writeAll(fd, Data("HEAD /_ping HTTP/1.1\r\nHost: d\r\n\r\n".utf8))
        Thread.sleep(forTimeInterval: 0.3)
        #expect(px.activeTransfers() == 0)
        _ = UnixSocket.writeAll(fd, Data("POST /v1.54/images/create?fromImage=alpine HTTP/1.1\r\nHost: d\r\n\r\n".utf8))
        Thread.sleep(forTimeInterval: 0.3)
        #expect(px.activeTransfers() == 1)
    }

    @Test func requestLineIgnoresBodyBytes() {
        #expect(SocketProxy.requestLine(Array("POST /build HTTP/1.1\r\n".utf8), 22) == "POST /build HTTP/1.1")
        #expect(SocketProxy.requestLine([0x1f, 0x8b, 0x08], 3) == "")    // gzip body
        #expect(SocketProxy.requestLine(Array("{\"a\":1}".utf8), 7) == "")
    }
}

@Suite struct VersionTests {
    @Test func comparesNumerically() {
        #expect(Version.isNewer("0.10.0", than: "0.9.9"))
        #expect(Version.isNewer("v0.3.0", than: "0.2.0"))
        #expect(Version.isNewer("1.0", than: "0.99.99"))
        #expect(!Version.isNewer("0.2.0", than: "0.2.0"))
        #expect(!Version.isNewer("0.1.9", than: "0.2.0"))
    }

    @Test func ignoresBuildSuffixesAndPadsMissingParts() {
        #expect(!Version.isNewer("0.2.0", than: "0.2.0-4-gabc123-dirty"))
        #expect(Version.isNewer("0.2.1", than: "0.2.0-4-gabc123"))
        #expect(!Version.isNewer("0.2", than: "0.2.0"))
    }

    @Test func devBuildsNeverNag() {
        #expect(!Version.isNewer("0.3.0", than: "dev"))
        #expect(!Version.isNewer("garbage", than: "0.1.0"))
    }
}

@Suite struct StartDetectionTests {
    @Test func foregroundSupervisorIsNotAStart() {
        #expect(!ColimaModel.isStartInProgress(command: "/opt/homebrew/bin/colima start -f\n", profile: "default"))
        #expect(!ColimaModel.isStartInProgress(command: "colima start --foreground", profile: "default"))
    }

    @Test func matchesStartsForTheProfile() {
        #expect(ColimaModel.isStartInProgress(command: "/opt/homebrew/bin/colima start\n", profile: "default"))
        #expect(ColimaModel.isStartInProgress(command: "colima start --profile work", profile: "work"))
        #expect(ColimaModel.isStartInProgress(command: "colima restart -p work", profile: "work"))
        #expect(ColimaModel.isStartInProgress(command: "colima start work --cpu 4", profile: "work"))
        #expect(ColimaModel.isStartInProgress(command: "colima start --profile=work", profile: "work"))
    }

    @Test func ignoresOtherProfilesAndCommands() {
        #expect(!ColimaModel.isStartInProgress(command: "colima start --profile work", profile: "default"))
        #expect(!ColimaModel.isStartInProgress(command: "colima status", profile: "default"))
        #expect(!ColimaModel.isStartInProgress(command: "vim colima start notes", profile: "default"))
    }
}

@Suite struct WorkClassificationTests {
    @Test func buildsPullsPushesCount() {
        #expect(SocketProxy.isWork("POST /v1.54/build?t=app HTTP/1.1"))
        #expect(SocketProxy.isWork("POST /v1.54/images/create?fromImage=alpine HTTP/1.1"))
        #expect(SocketProxy.isWork("POST /v1.54/images/registry.io/app:1/push HTTP/1.1"))
        #expect(SocketProxy.isWork("POST /v1.54/images/load HTTP/1.1"))
        #expect(SocketProxy.isWork("GET /v1.54/images/get?names=a HTTP/1.1"))
        #expect(SocketProxy.isWork("POST /session HTTP/1.1"))
        #expect(SocketProxy.isWork("POST /v1.54/grpc HTTP/1.1"))
        #expect(SocketProxy.isWork("POST /commit?container=x HTTP/1.1"))
    }

    @Test func pollingAndStreamsDoNot() {
        #expect(!SocketProxy.isWork("GET /v1.54/containers/json HTTP/1.1"))
        #expect(!SocketProxy.isWork("GET /v1.54/events HTTP/1.1"))
        #expect(!SocketProxy.isWork("HEAD /_ping HTTP/1.1"))
        #expect(!SocketProxy.isWork("GET /v1.54/containers/x/logs?follow=1 HTTP/1.1"))
        #expect(!SocketProxy.isWork("POST /v1.54/containers/create HTTP/1.1"))
        #expect(!SocketProxy.isWork("garbage"))
    }
}

@Suite struct ShellRunTests {
    @Test func returnsAllOutput() async {
        let r = await Shell.run(["sh", "-c", "i=0; while [ $i -lt 2000 ]; do echo line$i; i=$((i+1)); done"])
        #expect(r.ok)
        let lines = r.out.split(separator: "\n")
        #expect(lines.count == 2000)
        #expect(lines.last == "line1999")
    }

    @Test func orphanHoldingThePipeDoesNotHang() async {
        let start = Date()
        let r = await Shell.run(["sh", "-c", "sleep 5 & echo hi"])
        #expect(r.ok)
        #expect(r.out == "hi\n")
        #expect(Date().timeIntervalSince(start) < 3)
    }
}
