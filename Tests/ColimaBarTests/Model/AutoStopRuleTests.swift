import Foundation
import Testing

@testable import ColimaBar

@Suite struct AutoStopRuleTests {
    private func check(
        enabled: Bool = true, isRunning: Bool = true, isBusy: Bool = false, containers: Int? = 0, transfers: Int = 0,
        since: SuspendingClock.Instant?, now: SuspendingClock.Instant, minutes: Int = 30
    ) -> AutoStopRule.Check {
        AutoStopRule.evaluate(
            enabled: enabled, isRunning: isRunning, isBusy: isBusy, runningContainers: containers,
            transfers: transfers, idleSince: since, now: now, idleMinutes: minutes)
    }

    @Test func idleTimeStartsThenBecomesDue() {
        var clock = TestInstants()
        let start = clock.now
        let first = check(since: nil, now: clock.now)
        #expect(first == AutoStopRule.Check(idleSince: start, isDue: false))
        clock.advance(29 * 60)
        #expect(check(since: first.idleSince, now: clock.now) == AutoStopRule.Check(idleSince: start, isDue: false))
        clock.advance(60)
        #expect(check(since: first.idleSince, now: clock.now) == AutoStopRule.Check(idleSince: start, isDue: true))
    }

    @Test func anyActivityResetsTheIdleTime() {
        var clock = TestInstants()
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
        var clock = TestInstants()
        let since = clock.now
        clock.advance(3600)
        #expect(
            check(containers: nil, since: since, now: clock.now) == AutoStopRule.Check(idleSince: nil, isDue: false))
    }

    @Test func eachProfileKeepsItsOwnIdleTime() {
        // Two profiles that became idle at different times reach the
        // timeout at different times.
        var clock = TestInstants()
        let a = check(since: nil, now: clock.now)
        clock.advance(10 * 60)
        let b = check(since: nil, now: clock.now)
        clock.advance(20 * 60)
        #expect(check(since: a.idleSince, now: clock.now).isDue)
        #expect(!check(since: b.idleSince, now: clock.now).isDue)
        clock.advance(10 * 60)
        #expect(check(since: b.idleSince, now: clock.now).isDue)
    }

    @Test func stopTimeMovesLaterByTheSleepTime() {
        // The Mac sleeps 8 hours: the wall clock moves 8 hours, the instants do not.
        let wall = Date(timeIntervalSince1970: 1_800_000_000)
        let since = SuspendingClock.now
        let now = since + .seconds(10 * 60)
        let before = AutoStopRule.stopTime(idleSince: since, now: now, wallNow: wall, idleMinutes: 30)
        #expect(before == wall.addingTimeInterval(20 * 60))
        let after = AutoStopRule.stopTime(
            idleSince: since, now: now, wallNow: wall.addingTimeInterval(8 * 3600), idleMinutes: 30)
        #expect(after == before.addingTimeInterval(8 * 3600))
    }

    @Test func stopTimeKeepsTheFractionOfASecond() {
        let wall = Date(timeIntervalSince1970: 1_800_000_000)
        let since = SuspendingClock.now
        let now = since + .milliseconds(1500)
        let stop = AutoStopRule.stopTime(idleSince: since, now: now, wallNow: wall, idleMinutes: 30)
        #expect(abs(stop.timeIntervalSince(wall) - (30 * 60 - 1.5)) < 0.000_001)
    }

    @Test func stopTimeStaysWhileTheMacIsAwake() {
        // Both clocks move by the same time: the stop time does not change.
        let wall = Date(timeIntervalSince1970: 1_800_000_000)
        let since = SuspendingClock.now
        let a = AutoStopRule.stopTime(idleSince: since, now: since, wallNow: wall, idleMinutes: 30)
        let b = AutoStopRule.stopTime(
            idleSince: since, now: since + .seconds(300), wallNow: wall.addingTimeInterval(300), idleMinutes: 30)
        #expect(a == b)
    }

    @Test func stopTimeIsPublishedOnlyWhenItMovedBySeconds() {
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(!AutoStopRule.stopTimeMoved(old: nil, new: nil))
        #expect(AutoStopRule.stopTimeMoved(old: nil, new: t))
        #expect(AutoStopRule.stopTimeMoved(old: t, new: nil))
        #expect(!AutoStopRule.stopTimeMoved(old: t, new: t.addingTimeInterval(0.9)))
        #expect(AutoStopRule.stopTimeMoved(old: t, new: t.addingTimeInterval(-1)))
        #expect(AutoStopRule.stopTimeMoved(old: t, new: t.addingTimeInterval(3600)))
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

    // MARK: - Limit for the power state

    private func limit(
        _ minutes: Int, battery: Bool = false, lowPower: Bool = false, hot: Bool = false, sooner: Bool = true
    ) -> AutoStopRule.Limit {
        AutoStopRule.limit(
            minutes: minutes, power: PowerState(onBattery: battery, lowPowerMode: lowPower, isHot: hot),
            stopSooner: sooner)
    }

    @Test func limitIsTheUserTimeOnTheCharger() {
        #expect(limit(30) == AutoStopRule.Limit(minutes: 30, reason: nil))
    }

    @Test func limitCapsTheTimeOnBattery() {
        #expect(limit(30, battery: true) == AutoStopRule.Limit(minutes: 10, reason: .battery))
        #expect(limit(5, battery: true) == AutoStopRule.Limit(minutes: 5, reason: nil))
        #expect(limit(10, battery: true) == AutoStopRule.Limit(minutes: 10, reason: nil))
    }

    @Test func limitCapsTheTimeInLowPowerMode() {
        #expect(limit(30, lowPower: true) == AutoStopRule.Limit(minutes: 5, reason: .lowPowerMode))
        #expect(limit(3, lowPower: true) == AutoStopRule.Limit(minutes: 3, reason: nil))
    }

    @Test func lowPowerModeWinsOverBattery() {
        #expect(limit(8, battery: true, lowPower: true) == AutoStopRule.Limit(minutes: 5, reason: .lowPowerMode))
    }

    @Test func limitIsTheUserTimeWhenStopSoonerIsOff() {
        #expect(limit(30, battery: true, lowPower: true, sooner: false) == AutoStopRule.Limit(minutes: 30, reason: nil))
    }

    @Test func aHotMacDoesNotChangeTheLimit() {
        #expect(limit(30, hot: true) == AutoStopRule.Limit(minutes: 30, reason: nil))
    }

    @Test func limitNotesNameTheReason() {
        #expect(AutoStopRule.Reason.battery.note == "on battery")
        #expect(AutoStopRule.Reason.lowPowerMode.note == "Low Power Mode")
    }

    @Test func aShorterLimitKeepsTheIdleStartAndMovesTheStopTimeEarlier() {
        // 12 minutes idle: not due with 30 minutes, due with 10 minutes, same idle start.
        var clock = TestInstants()
        let start = clock.now
        clock.advance(12 * 60)
        let wall = Date(timeIntervalSince1970: 1_800_000_000)
        let onCharger = check(since: start, now: clock.now, minutes: 30)
        let onBattery = check(since: start, now: clock.now, minutes: 10)
        #expect(onCharger == AutoStopRule.Check(idleSince: start, isDue: false))
        #expect(onBattery == AutoStopRule.Check(idleSince: start, isDue: true))
        let later = AutoStopRule.stopTime(idleSince: start, now: clock.now, wallNow: wall, idleMinutes: 30)
        let sooner = AutoStopRule.stopTime(idleSince: start, now: clock.now, wallNow: wall, idleMinutes: 10)
        #expect(later.timeIntervalSince(sooner) == 20 * 60)
        #expect(AutoStopRule.stopTimeMoved(old: later, new: sooner))
    }

    @Test func stillDueNeedsAnIdleStartAndEnoughTime() {
        var clock = TestInstants()
        let start = clock.now
        clock.advance(12 * 60)
        #expect(AutoStopRule.stillDue(idleSince: start, now: clock.now, minutes: 10))
        #expect(AutoStopRule.stillDue(idleSince: start, now: clock.now, minutes: 12))
        #expect(!AutoStopRule.stillDue(idleSince: start, now: clock.now, minutes: 30))
        #expect(!AutoStopRule.stillDue(idleSince: nil, now: clock.now, minutes: 10))
    }
}
