import Foundation
import Testing

@testable import ColimaBar

@Suite struct ImageUpdateScheduleTests {
    private typealias S = ImageUpdateSchedule
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let hour: TimeInterval = 3600
    private func ago(_ s: TimeInterval) -> Date { now.addingTimeInterval(-s) }
    private let digest = "sha256:" + String(repeating: "1", count: 64)

    private func may(
        enabled: Bool = true, debug: Bool = false, restarting: Bool = false, running: Bool = true,
        docker: Bool = true, busy: String? = nil, inFlight: Int = 0, waking: Bool = false, transfer: Bool = false,
        proxy: Int = 0, trimming: Bool = false, recreating: Bool = false, checking: Bool = false
    ) -> Bool {
        S.mayRun(
            enabled: enabled, isDebug: debug, updateRestarting: restarting, running: running, hasDockerSocket: docker,
            busyMarker: busy, actionsInFlight: inFlight, waking: waking, transferring: transfer, proxyTransfers: proxy,
            trimming: trimming, recreating: recreating, checking: checking)
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
        #expect(!may(recreating: true))
        #expect(!may(checking: true))
    }

    @Test func aRunStartsHourlyAtMost() {
        #expect(S.isDue(lastRun: nil, now: now))
        #expect(!S.isDue(lastRun: ago(59 * 60), now: now))
        #expect(S.isDue(lastRun: ago(hour), now: now))
    }

    @Test func aClockThatWentBackIsDue() {
        #expect(S.isDue(lastRun: now.addingTimeInterval(2 * 24 * hour), now: now))
        #expect(!S.isDue(lastRun: now.addingTimeInterval(hour), now: now))
    }

    @Test func checkNowWorksOnceInFiveMinutes() {
        #expect(S.checkNowAllowed(last: nil, now: now))
        #expect(!S.checkNowAllowed(last: ago(299), now: now))
        #expect(S.checkNowAllowed(last: ago(300), now: now))
        #expect(S.checkNowAllowed(last: now.addingTimeInterval(2 * 24 * hour), now: now))
    }

    // MARK: - Entries

    private func entry(_ age: TimeInterval, error: ImageUpdateStatus.Failure? = nil) -> ImageUpdateCache.Entry {
        .init(digest: error == nil ? digest : nil, error: error, checkedAt: ago(age))
    }

    @Test func aGoodEntryIsFreshForADay() {
        #expect(S.isStale(nil, now: now))
        #expect(!S.isStale(entry(23 * hour), now: now))
        #expect(S.isStale(entry(24 * hour), now: now))
        #expect(S.isStale(entry(-3 * 24 * hour), now: now))  // a wrong clock
    }

    @Test func failuresAreFreshForTheirOwnTime() {
        #expect(!S.isStale(entry(59 * 60, error: .unreachable), now: now))
        #expect(S.isStale(entry(hour, error: .unreachable), now: now))
        #expect(!S.isStale(entry(5 * hour, error: .rateLimited), now: now))
        #expect(S.isStale(entry(6 * hour, error: .rateLimited), now: now))
        #expect(!S.isStale(entry(23 * hour, error: .signInNeeded), now: now))
        #expect(!S.isStale(entry(23 * hour, error: .notFound), now: now))
    }

    // MARK: - The plan

    private let hub = ImageUpdateCache.HubBudget()
    private func refs(_ names: [String]) -> [ImageRef] { names.compactMap(ImageRef.parse) }

    @Test func onlyStaleReferencesAreChecked() {
        let all = refs(["a", "b", "ghcr.io/o/c"])
        let entries = [
            "docker.io/library/a:latest": entry(hour), "ghcr.io/o/c:latest": entry(25 * hour),
        ]
        let plan = S.plan(refs: all, entries: entries, hub: hub, now: now)
        #expect(plan.map(\.normalized) == ["docker.io/library/b:latest", "ghcr.io/o/c:latest"])
    }

    @Test func dockerHubGetsThreeReferencesOfOneRunTheOldestFirst() {
        let all = refs(["a", "b", "c", "d", "e"])
        let entries = [
            "docker.io/library/a:latest": entry(30 * hour), "docker.io/library/b:latest": entry(48 * hour),
            "docker.io/library/c:latest": entry(25 * hour),
        ]
        let plan = S.plan(refs: all, entries: entries, hub: hub, now: now)
        // d and e have no entry yet: they come first, in name order.
        #expect(
            plan.map(\.normalized) == [
                "docker.io/library/d:latest", "docker.io/library/e:latest", "docker.io/library/b:latest",
            ])
    }

    @Test func otherRegistriesGetTwentyFiveReferences() {
        let all = refs((0..<40).map { "ghcr.io/o/app\($0)" } + ["a", "b", "c", "d"])
        let plan = S.plan(refs: all, entries: [:], hub: hub, now: now)
        #expect(plan.filter { !$0.isDockerHub }.count == 25)
        #expect(plan.filter(\.isDockerHub).count == 3)
    }

    // MARK: - The Docker Hub budget

    private func calls(_ agos: [TimeInterval]) -> ImageUpdateCache.HubBudget {
        .init(calls: agos.map { ago($0).timeIntervalSince1970 })
    }

    @Test func dockerHubAllowsThreeCallsInAnHour() {
        #expect(S.hubAllowance(hub, now: now) == 3)
        #expect(S.hubAllowance(calls([60]), now: now) == 2)
        #expect(S.hubAllowance(calls([60, 120, 3599]), now: now) == 0)
        // A call leaves the window after an hour.
        #expect(S.hubAllowance(calls([60, 120, 3600]), now: now) == 1)
        // A call from the far future is a wrong clock.
        #expect(S.hubAllowance(calls([-3 * 24 * hour]), now: now) == 3)
    }

    @Test func theBudgetLimitsThePlanAndLeavesOtherRegistries() {
        let all = refs(["a", "b", "c", "ghcr.io/o/d"])
        let plan = S.plan(refs: all, entries: [:], hub: calls([60, 120]), now: now)
        #expect(plan.map(\.normalized) == ["docker.io/library/a:latest", "ghcr.io/o/d:latest"])
        let spent = S.plan(refs: all, entries: [:], hub: calls([60, 120, 180]), now: now)
        #expect(spent.map(\.normalized) == ["ghcr.io/o/d:latest"])
    }

    @Test func spendingAddsCallsAndDropsOldOnes() {
        let next = S.hubSpent(calls([60, 2 * hour]), calls: 2, rateLimited: false, now: now)
        #expect(next.calls.count == 3 && next.pausedUntil == nil)
        #expect(S.hubAllowance(next, now: now) == 0)
    }

    @Test func aRateLimitAnswerPausesDockerHubForSixHours() {
        let paused = S.hubSpent(hub, calls: 1, rateLimited: true, now: now)
        #expect(S.hubAllowance(paused, now: now.addingTimeInterval(5 * hour)) == 0)
        #expect(S.hubAllowance(paused, now: now.addingTimeInterval(6 * hour)) == 3)
        let all = refs(["a", "ghcr.io/o/c"])
        #expect(S.plan(refs: all, entries: [:], hub: paused, now: now).map(\.normalized) == ["ghcr.io/o/c:latest"])
        // A pause that ended is forgotten at the next spend.
        let later = S.hubSpent(paused, calls: 0, rateLimited: false, now: now.addingTimeInterval(7 * hour))
        #expect(later.pausedUntil == nil)
        // A pause from a wrong clock does not hold Docker Hub for ever.
        let wrong = ImageUpdateCache.HubBudget(
            pausedUntil: now.addingTimeInterval(30 * 24 * hour).timeIntervalSince1970)
        #expect(S.hubAllowance(wrong, now: now) == 3)
    }

    @Test func checkNowChecksOlderReferencesAgainButKeepsTheBudgetAndTheHour() {
        let all = refs(["a", "b", "c", "d"])
        let fresh = Dictionary(
            uniqueKeysWithValues: all.map { ($0.normalized, entry(Double(all.firstIndex(of: $0)!) * hour + hour)) })
        #expect(S.plan(refs: all, entries: fresh, hub: hub, now: now).isEmpty)
        // a was checked an hour ago, so it is not the first to wait. A check from the last hour would wait.
        let forced = S.plan(refs: all, entries: fresh, hub: hub, now: now, force: true)
        #expect(
            forced.map(\.normalized) == [
                "docker.io/library/d:latest", "docker.io/library/c:latest", "docker.io/library/b:latest",
            ])
        let recent = fresh.merging(["docker.io/library/d:latest": entry(30 * 60)]) { $1 }
        let skipped = S.plan(refs: all, entries: recent, hub: hub, now: now, force: true)
        #expect(
            skipped.map(\.normalized) == [
                "docker.io/library/c:latest", "docker.io/library/b:latest", "docker.io/library/a:latest",
            ])
        #expect(S.plan(refs: all, entries: fresh, hub: calls([60, 120, 180]), now: now, force: true).isEmpty)
    }
}
