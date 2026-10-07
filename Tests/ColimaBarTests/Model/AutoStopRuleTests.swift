import Foundation
import Testing

@testable import ColimaBar

@Suite struct AutoStopRuleTests {
    private func check(
        enabled: Bool = true, isRunning: Bool = true, isBusy: Bool = false, containers: Int? = 0, transfers: Int = 0,
        since: Date?, now: Date, minutes: Int = 30
    ) -> AutoStopRule.Check {
        AutoStopRule.evaluate(
            enabled: enabled, isRunning: isRunning, isBusy: isBusy, runningContainers: containers,
            transfers: transfers, idleSince: since, now: now, idleMinutes: minutes)
    }

    @Test func idleTimeStartsThenBecomesDue() {
        let clock = TestClock()
        let start = clock.now
        let first = check(since: nil, now: clock.now)
        #expect(first == AutoStopRule.Check(idleSince: start, isDue: false))
        clock.advance(29 * 60)
        #expect(check(since: first.idleSince, now: clock.now) == AutoStopRule.Check(idleSince: start, isDue: false))
        clock.advance(60)
        #expect(check(since: first.idleSince, now: clock.now) == AutoStopRule.Check(idleSince: start, isDue: true))
    }

    @Test func anyActivityResetsTheIdleTime() {
        let clock = TestClock()
        let since = clock.now
        clock.advance(3600)
        let reset = AutoStopRule.Check(idleSince: nil, isDue: false)
        #expect(check(enabled: false, since: since, now: clock.now) == reset)
        #expect(check(isRunning: false, since: since, now: clock.now) == reset)
        #expect(check(isBusy: true, since: since, now: clock.now) == reset)
        #expect(check(containers: 1, since: since, now: clock.now) == reset)
        #expect(check(transfers: 1, since: since, now: clock.now) == reset)
    }

    @Test func anUnknownContainerListIsNotIdle() {
        let clock = TestClock()
        let since = clock.now
        clock.advance(3600)
        #expect(
            check(containers: nil, since: since, now: clock.now) == AutoStopRule.Check(idleSince: nil, isDue: false))
    }

    @Test func eachProfileKeepsItsOwnIdleTime() {
        // Two profiles that became idle at different times reach the
        // timeout at different times.
        let clock = TestClock()
        let a = check(since: nil, now: clock.now)
        clock.advance(10 * 60)
        let b = check(since: nil, now: clock.now)
        clock.advance(20 * 60)
        #expect(check(since: a.idleSince, now: clock.now).isDue)
        #expect(!check(since: b.idleSince, now: clock.now).isDue)
        clock.advance(10 * 60)
        #expect(check(since: b.idleSince, now: clock.now).isDue)
    }

    @Test func otherProfilesAreTheRunningDockerProfilesExceptTheSelectedOne() {
        let rows = [
            ProfileRow(name: "default", isRunning: true, cpus: 2, memGB: 2, runtime: "docker"),
            ProfileRow(name: "work", isRunning: true, cpus: 2, memGB: 2, runtime: "docker"),
            ProfileRow(name: "old", isRunning: true, cpus: 2, memGB: 2, runtime: ""),
            ProfileRow(name: "ctrd", isRunning: true, cpus: 2, memGB: 2, runtime: "containerd"),
            ProfileRow(name: "idle", isRunning: false, cpus: 2, memGB: 2, runtime: "docker"),
        ]
        #expect(AutoStopRule.otherProfiles(rows, selected: "default") == ["work", "old"])
        #expect(AutoStopRule.otherProfiles(rows, selected: "work") == ["default", "old"])
    }

    @Test func otherProfilesAreCheckedEachInterval() {
        let clock = TestClock()
        #expect(AutoStopRule.isCheckDue(lastCheck: nil, now: clock.now))
        let last = clock.now
        clock.advance(AutoStopRule.otherCheckInterval - 1)
        #expect(!AutoStopRule.isCheckDue(lastCheck: last, now: clock.now))
        clock.advance(1)
        #expect(AutoStopRule.isCheckDue(lastCheck: last, now: clock.now))
    }
}
