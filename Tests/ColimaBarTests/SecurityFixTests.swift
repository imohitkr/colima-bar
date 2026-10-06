import Foundation
import Testing
@testable import ColimaBar

@Suite struct ReleaseLinkTests {
    private func trusted(_ s: String) -> Bool { ReleaseLink.isTrusted(URL(string: s)!) }

    @Test func acceptsThisRepoReleasePages() {
        #expect(trusted("https://github.com/imohitkr/colima-bar/releases/tag/v0.4.0"))
        #expect(trusted("https://github.com/imohitkr/colima-bar/releases/latest"))
        #expect(trusted("HTTPS://GitHub.com/imohitkr/colima-bar/releases/tag/v1.0.0"))
    }

    @Test func rejectsOtherSchemes() {
        #expect(!trusted("http://github.com/imohitkr/colima-bar/releases/tag/v0.4.0"))
        #expect(!trusted("file:///imohitkr/colima-bar/releases/x"))
        #expect(!trusted("file:///Applications/Calculator.app"))
        #expect(!trusted("x-apple.systempreferences:com.apple.Notifications-Settings.extension"))
        #expect(!trusted("colimabar://github.com/imohitkr/colima-bar/releases/x"))
    }

    @Test func rejectsOtherHostsAndRepos() {
        #expect(!trusted("https://evil.example/imohitkr/colima-bar/releases/tag/v0.4.0"))
        #expect(!trusted("https://github.com.evil.example/imohitkr/colima-bar/releases/tag/v0.4.0"))
        #expect(!trusted("https://github.com@evil.example/imohitkr/colima-bar/releases/tag/v0.4.0"))
        #expect(!trusted("https://github.com:8443/imohitkr/colima-bar/releases/tag/v0.4.0"))
        #expect(!trusted("https://github.com/someone/colima-bar/releases/tag/v0.4.0"))
        #expect(!trusted("https://github.com/imohitkr/colima-bar-fork/releases/tag/v0.4.0"))
        #expect(!trusted("https://github.com/imohitkr/colima-bar/issues/1"))
        #expect(!trusted("https://github.com/imohitkr/colima-bar/releases/../../other/repo"))
    }

    @Test func pageFallsBackToLatest() {
        let good = URL(string: "https://github.com/imohitkr/colima-bar/releases/tag/v0.4.0")!
        #expect(ReleaseLink.page(good) == good)
        #expect(ReleaseLink.page(URL(string: "http://github.com/imohitkr/colima-bar/releases/tag/v0.4.0")!) == ReleaseLink.latest)
        #expect(ReleaseLink.page(nil) == ReleaseLink.latest)
        #expect(ReleaseLink.latest.absoluteString == "https://github.com/imohitkr/colima-bar/releases/latest")
    }
}

@Suite struct AlertThrottleTests {
    /// A clock that the test moves forward by hand.
    final class FakeClock: @unchecked Sendable {
        var now = Date(timeIntervalSince1970: 1_000_000)
    }

    /// Holds the throttle, so #expect can call its mutating method.
    final class Box {
        var t: AlertThrottle
        init(_ clock: FakeClock) { t = AlertThrottle(window: 600, clock: { clock.now }) }
        func allow(_ key: String) -> Bool { t.allow(key) }
    }

    @Test func postsOncePerWindowForTheSameKey() {
        let clock = FakeClock()
        let t = Box(clock)
        let key = AlertThrottle.key(container: "abc", body: "Exited with code 1")
        #expect(t.allow(key))
        clock.now += 60
        #expect(!t.allow(key))
        clock.now += 539   // 599 s after the first banner
        #expect(!t.allow(key))
        clock.now += 1     // 600 s: the window is over
        #expect(t.allow(key))
        clock.now += 1
        #expect(!t.allow(key))
    }

    @Test func keysAreSeparateByContainerAndKind() {
        let clock = FakeClock()
        let t = Box(clock)
        #expect(t.allow(AlertThrottle.key(container: "abc", body: "Exited with code 1")))
        #expect(t.allow(AlertThrottle.key(container: "def", body: "Exited with code 1")))
        #expect(t.allow(AlertThrottle.key(container: "abc", body: "Killed: out of memory")))
        #expect(t.allow(AlertThrottle.key(container: "abc", body: "Healthcheck is failing")))
        // A different exit code is the same kind of alert.
        #expect(!t.allow(AlertThrottle.key(container: "abc", body: "Exited with code 2")))
    }

    @Test func oldEntriesArePruned() {
        let clock = FakeClock()
        let t = Box(clock)
        for i in 0..<150 { #expect(t.allow("k\(i)")) }
        clock.now += 601
        #expect(t.allow("k0"))
        #expect(!t.allow("k0"))
    }
}
