import Foundation
import Testing

@testable import ColimaBar

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
        clock.now += 539  // 599 s after the first banner
        #expect(!t.allow(key))
        clock.now += 1  // 600 s: the window is over
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
