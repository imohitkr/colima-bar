import Foundation
import Testing

@testable import ColimaBar

@Suite struct PruneScheduleTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let day: TimeInterval = 24 * 3600
    private func ago(_ s: TimeInterval) -> Date { now.addingTimeInterval(-s) }

    @Test func noLastRunIsDue() {
        #expect(PruneSchedule.isDue(lastRun: nil, retryAt: nil, now: now))
    }

    @Test func sixDaysIsNotDue() {
        #expect(!PruneSchedule.isDue(lastRun: ago(6 * day), retryAt: nil, now: now))
    }

    @Test func sevenDaysIsDue() {
        #expect(PruneSchedule.isDue(lastRun: ago(7 * day), retryAt: nil, now: now))
    }

    @Test func aWaitThatHasNotEndedIsNotDue() {
        #expect(!PruneSchedule.isDue(lastRun: nil, retryAt: now.addingTimeInterval(30 * 60), now: now))
        #expect(PruneSchedule.isDue(lastRun: nil, retryAt: ago(60), now: now))
    }

    /// A wait that is far in the future comes from a wrong clock. It must not
    /// block the cleanup for ever.
    @Test func aWaitFurtherAwayThanTheLongestWaitIsIgnored() {
        let far = now.addingTimeInterval(PruneSchedule.failedRetryAfter + 60)
        #expect(PruneSchedule.isDue(lastRun: nil, retryAt: far, now: now))
    }

    /// A last run far in the future is a wrong date. It must not block the
    /// cleanup for ever.
    @Test func aClockThatWentBackIsDue() {
        #expect(PruneSchedule.isDue(lastRun: now.addingTimeInterval(2 * day), retryAt: nil, now: now))
        #expect(!PruneSchedule.isDue(lastRun: now.addingTimeInterval(day / 2), retryAt: nil, now: now))
    }

    @Test func aGoodRunNeedsNoWait() {
        #expect(PruneSchedule.retryAt(afterStatus: 0, now: now) == nil)
    }

    @Test func aFailedRunWaitsSixHoursAndABusyVMOneHour() {
        #expect(PruneSchedule.retryAt(afterStatus: 1, now: now) == now.addingTimeInterval(6 * 3600))
        #expect(PruneSchedule.retryAt(afterStatus: 2, now: now) == now.addingTimeInterval(3600))
        #expect(PruneSchedule.retryAt(afterStatus: 143, now: now) == now.addingTimeInterval(3600))
    }

    private func may(
        enabled: Bool = true, debug: Bool = false, restarting: Bool = false, running: Bool = true,
        docker: Bool = true, busy: String? = nil, inFlight: Int = 0, waking: Bool = false, transfer: Bool = false,
        proxy: Int = 0, trimming: Bool = false
    ) -> Bool {
        PruneSchedule.mayRun(
            enabled: enabled, isDebug: debug, updateRestarting: restarting, running: running, hasDockerSocket: docker,
            busyMarker: busy, actionsInFlight: inFlight, waking: waking, transferring: transfer, proxyTransfers: proxy,
            trimming: trimming)
    }

    @Test func allClearMayRun() { #expect(may()) }

    @Test func eachBlockingInputStopsTheRun() {
        #expect(!may(enabled: false))
        #expect(!may(debug: true))
        #expect(!may(restarting: true))
        #expect(!may(running: false))
        #expect(!may(docker: false))
        #expect(!may(busy: "Starting"))
        #expect(!may(inFlight: 1))
        #expect(!may(waking: true))
        #expect(!may(transfer: true))
        #expect(!may(proxy: 1))
        #expect(!may(trimming: true))
    }

    @Test func onlyExitZeroCountsAsARun() {
        #expect(PruneSchedule.countsAsRun(status: 0))
        #expect(!PruneSchedule.countsAsRun(status: 1))
        #expect(!PruneSchedule.countsAsRun(status: 2))
        #expect(!PruneSchedule.countsAsRun(status: 143))
    }

    @Test func decodeDropsBadEntries() {
        let raw: [String: Any] = ["default": 100.0, "bad": "x", "neg": -5.0, "nan": Double.nan]
        #expect(PruneSchedule.decode(raw) == ["default": Date(timeIntervalSince1970: 100)])
        #expect(PruneSchedule.decode(nil).isEmpty)
    }

    @Test func encodeAndDecodeRoundTrip() {
        let runs = ["default": Date(timeIntervalSince1970: 1000), "work": Date(timeIntervalSince1970: 2000)]
        #expect(PruneSchedule.decode(PruneSchedule.encode(runs)) == runs)
    }
}
