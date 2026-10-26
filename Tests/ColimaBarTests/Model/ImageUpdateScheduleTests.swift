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

    private func refs(_ names: [String]) -> [ImageRef] { names.compactMap(ImageRef.parse) }

    @Test func onlyStaleReferencesAreChecked() {
        let all = refs(["a", "b", "ghcr.io/o/c"])
        let entries = [
            "docker.io/library/a:latest": entry(hour), "ghcr.io/o/c:latest": entry(25 * hour),
        ]
        let plan = S.plan(refs: all, entries: entries, now: now)
        #expect(plan.map(\.normalized) == ["docker.io/library/b:latest", "ghcr.io/o/c:latest"])
    }

    @Test func dockerHubGetsThreeReferencesOfOneRunTheOldestFirst() {
        let all = refs(["a", "b", "c", "d", "e"])
        let entries = [
            "docker.io/library/a:latest": entry(30 * hour), "docker.io/library/b:latest": entry(48 * hour),
            "docker.io/library/c:latest": entry(25 * hour),
        ]
        let plan = S.plan(refs: all, entries: entries, now: now)
        // d and e have no entry yet: they come first, in name order.
        #expect(
            plan.map(\.normalized) == [
                "docker.io/library/d:latest", "docker.io/library/e:latest", "docker.io/library/b:latest",
            ])
    }

    @Test func otherRegistriesGetTwentyFiveReferences() {
        let all = refs((0..<40).map { "ghcr.io/o/app\($0)" } + ["a", "b", "c", "d"])
        let plan = S.plan(refs: all, entries: [:], now: now)
        #expect(plan.filter { !$0.isDockerHub }.count == 25)
        #expect(plan.filter(\.isDockerHub).count == 3)
    }

    @Test func aRateLimitedDockerHubWaitsSixHours() {
        let all = refs(["a", "b", "ghcr.io/o/c"])
        let limited = ["docker.io/library/zzz:1": entry(5 * hour, error: .rateLimited)]
        #expect(S.hubPaused(entries: limited, now: now))
        #expect(S.plan(refs: all, entries: limited, now: now).map(\.normalized) == ["ghcr.io/o/c:latest"])
        let over = ["docker.io/library/zzz:1": entry(6 * hour, error: .rateLimited)]
        #expect(!S.hubPaused(entries: over, now: now))
        #expect(S.plan(refs: all, entries: over, now: now).count == 3)
    }

    @Test func aRateLimitOfAnotherRegistryDoesNotPauseDockerHub() {
        let entries = ["ghcr.io/o/c:latest": entry(hour, error: .rateLimited)]
        #expect(!S.hubPaused(entries: entries, now: now))
    }

    @Test func checkNowChecksFreshReferencesAgainButKeepsTheLimitsAndThePause() {
        let all = refs(["a", "b", "c", "d"])
        let fresh = Dictionary(
            uniqueKeysWithValues: all.map { ($0.normalized, entry(Double(all.firstIndex(of: $0)!) * hour + hour)) })
        #expect(S.plan(refs: all, entries: fresh, now: now).isEmpty)
        let forced = S.plan(refs: all, entries: fresh, now: now, force: true)
        #expect(
            forced.map(\.normalized) == [
                "docker.io/library/d:latest", "docker.io/library/c:latest", "docker.io/library/b:latest",
            ])
        let paused = fresh.merging(["docker.io/library/a:latest": entry(hour, error: .rateLimited)]) { $1 }
        #expect(S.plan(refs: all, entries: paused, now: now, force: true).isEmpty)
    }
}
