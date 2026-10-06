import Foundation
import Testing
@testable import ColimaBar

@Suite struct CustomIdleCommitTests {
    @Test func appliesOnlyAValidChangedValue() {
        #expect(IdleMinutes.commit("45", current: 30) == 45)
        #expect(IdleMinutes.commit(" 90 ", current: 30) == 90)
        #expect(IdleMinutes.commit("1440", current: 30) == 1440)
        // The same value changes nothing, so the idle timer keeps running.
        #expect(IdleMinutes.commit("30", current: 30) == nil)
        // Invalid text stays in the field (red) and is never applied.
        for s in ["", "0", "1441", "-5", "4.5", "abc"] {
            #expect(IdleMinutes.commit(s, current: 30) == nil, "\(s)")
        }
    }
}

@Suite @MainActor struct PickerOptionsTests {
    private let cpu = [2, 4, 6, 8, 10, 12]
    private let mem = [4, 8, 12, 16, 24, 32]

    @Test func keepsTheVMValueAfterAnotherIsPicked() {
        // Colima's default VM has 2 GB. After you pick 8 GB, 2 GB stays.
        #expect(SystemTab.options(mem, 2, 8) == [2, 4, 8, 12, 16, 24, 32])
        #expect(SystemTab.options(mem, 2, 2) == [2, 4, 8, 12, 16, 24, 32])
    }

    @Test func showsBothOffListValues() {
        #expect(SystemTab.options(cpu, 3, 5) == [2, 3, 4, 5, 6, 8, 10, 12])
        #expect(SystemTab.options(mem, 48, 2) == [2, 4, 8, 12, 16, 24, 32, 48])
    }

    @Test func listedOrUnknownValuesAddNothing() {
        #expect(SystemTab.options(cpu, 4, 8) == cpu)
        #expect(SystemTab.options(cpu, 0, 0) == cpu)     // VM facts not loaded yet
        #expect(SystemTab.options(mem) == mem)
    }
}

@Suite struct DFGateTests {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    /// Each call returns the step, so #expect does not capture `g` (it must mutate).
    private func ask(_ g: inout DFGate, at s: TimeInterval) -> DFGate.Step { g.request(now: t0.addingTimeInterval(s)) }
    private func done(_ g: inout DFGate, at s: TimeInterval) -> DFGate.Step { g.end(now: t0.addingTimeInterval(s)) }

    @Test func firstRequestRunsNowAndOthersJoinIt() {
        var g = DFGate()
        var steps = [ask(&g, at: 0), ask(&g, at: 0)]  // the second is already scheduled
        g.begin()
        steps += [ask(&g, at: 0), ask(&g, at: 0)]     // in flight: remembered
        // Requests during the run join into one more run after the gap.
        steps += [done(&g, at: 5), ask(&g, at: 6)]
        #expect(steps == [.run(after: 0), .none, .none, .none, .run(after: 30), .none])
    }

    @Test func noRequestDuringTheRunMeansNoRerun() {
        var g = DFGate()
        _ = ask(&g, at: 0)
        g.begin()
        let step = done(&g, at: 0)
        #expect(step == .none)
        #expect(!g.scheduled && !g.inFlight)
    }

    @Test func waitsForTheRestOfTheGap() {
        var g = DFGate()
        _ = ask(&g, at: 0)
        g.begin()
        _ = done(&g, at: 0)
        let first = ask(&g, at: 10)
        g.begin()
        _ = done(&g, at: 30)
        let second = ask(&g, at: 65)
        #expect(first == .run(after: 20))
        #expect(second == .run(after: 0))
    }

    @Test func skipAllowsALaterRequest() {
        var g = DFGate()
        _ = ask(&g, at: 0)
        g.skip()                                      // the tab closed during the wait
        let step = ask(&g, at: 0)
        #expect(step == .run(after: 0))
    }

    @Test func onlyDiskTabsWantDF() {
        #expect(!ColimaModel.showsDiskUsage(.containers))
        #expect(ColimaModel.showsDiskUsage(.images))
        #expect(ColimaModel.showsDiskUsage(.volumes))
        #expect(ColimaModel.showsDiskUsage(.system))
    }
}

@Suite struct EventFilterTests {
    private func decoded() throws -> [String: [String]] {
        let obj = try JSONSerialization.jsonObject(with: Data(ColimaModel.eventFilter.utf8))
        return try #require(obj as? [String: [String]])
    }

    @Test func listsTheTypesAndActionsTheHandlerUses() throws {
        let f = try decoded()
        #expect(Set(f.keys) == ["type", "event"])
        #expect(Set(f["type"] ?? []) == ["container", "image", "volume"])
        let actions = Set(f["event"] ?? [])
        for a in ["create", "start", "restart", "die", "stop", "kill", "oom", "pause", "unpause", "rename",
                  "destroy", "health_status", "pull", "tag", "untag", "delete", "import", "load", "prune"] {
            #expect(actions.contains(a), "\(a)")
        }
    }

    @Test func prefixMatchKeepsHealthAndDropsExecEvents() throws {
        // dockerd matches every action by prefix because "health_status" is listed.
        let actions = try decoded()["event"] ?? []
        func passes(_ action: String) -> Bool { actions.contains { action.hasPrefix($0) } }
        for a in ["health_status: unhealthy", "health_status: healthy", "die", "oom", "destroy"] {
            #expect(passes(a), "\(a)")
        }
        for a in ["exec_create: sh -c true", "exec_start: sh -c true", "exec_die", "exec_detach", "top",
                  "attach", "detach", "commit", "copy", "export", "resize", "update", "mount", "unmount",
                  "archive-path", "extract-to-dir", "push", "save"] {
            #expect(!passes(a), "\(a)")
        }
    }

    @Test func streamThreadDropsExecAndTop() {
        #expect(ColimaModel.ignores(action: "exec_start: /bin/sh -c curl"))
        #expect(ColimaModel.ignores(action: "top"))
        #expect(!ColimaModel.ignores(action: "die"))
        #expect(!ColimaModel.ignores(action: "health_status: unhealthy"))
    }
}

@Suite struct IdleTimingTests {
    @Test func slowTickWheneverClosedAndNotBusy() {
        for s in [VMState.running, .stopped, .unknown, .notInstalled] {
            #expect(ColimaModel.tickInterval(state: s, busy: false, dashboardOpen: false) == .seconds(5))
            #expect(ColimaModel.tickInterval(state: s, busy: false, dashboardOpen: true) == .seconds(1))
            #expect(ColimaModel.tickInterval(state: s, busy: true, dashboardOpen: false) == .seconds(1))
        }
    }

    @Test func listsRarelyAndOnOpenOnlyWhenOld() {
        #expect(ColimaModel.staleAfter(state: .running) == 300)
        #expect(ColimaModel.staleAfter(state: .stopped) == 300)
        #expect(ColimaModel.statusMaxAgeOnOpen == 60)
    }
}

/// Counts how many calls run at the same time.
private actor Gauge {
    var now = 0
    var peak = 0
    func enter() { now += 1; peak = max(peak, now) }
    func leave() { now -= 1 }
}

@Suite struct ProjectConcurrencyTests {
    @Test func runsAtMostEightAtOnceAndCollectsFailures() async {
        let gauge = Gauge()
        let ids = (0..<30).map { "c\($0)" }
        let failed = await ColimaModel.failures(ids, limit: ColimaModel.projectConcurrency) { id in
            await gauge.enter()
            try? await Task.sleep(for: .milliseconds(10))
            await gauge.leave()
            return id.hasSuffix("7") ? id : nil
        }
        #expect(failed.sorted() == ["c17", "c27", "c7"])
        let peak = await gauge.peak
        #expect(peak <= 8 && peak >= 2, "\(peak)")
        #expect(await ColimaModel.failures([String](), limit: 8) { $0 }.isEmpty)
    }
}

@Suite struct LogByteBudgetTests {
    private func lines(_ n: Int, size: Int) -> [LogLine] {
        (0..<n).map { i in LogLine(id: 0, time: "", text: String(format: "%05d", i) + String(repeating: "x", count: size - 5), stderr: false) }
    }

    @Test func dropCountHonoursBothLimits() {
        let l = lines(10, size: 100)
        #expect(LogTrim.dropCount(l, bytes: 1000, maxLines: 20, maxBytes: 2000) == (0, 0))
        #expect(LogTrim.dropCount(l, bytes: 1000, maxLines: 6, maxBytes: 2000) == (4, 400))
        #expect(LogTrim.dropCount(l, bytes: 1000, maxLines: 20, maxBytes: 350) == (7, 700))
        #expect(LogTrim.dropCount(l, bytes: 1000, maxLines: 8, maxBytes: 450) == (6, 600))
        #expect(LogTrim.dropCount(l, bytes: 1000, maxLines: 20, maxBytes: 0) == (10, 1000))
    }

    @Test func bufferKeepsNewestLinesWithinTheByteBudget() {
        let b = LogBuffer(cap: 10_000, byteCap: 10_000)
        for _ in 0..<50 { _ = b.push(lines(100, size: 100), lastTimestamp: nil) }   // 500 kB pushed
        let out = b.drain()
        #expect(out.count == 100)
        #expect(out.reduce(0) { $0 + $1.text.utf8.count } <= 10_000)
        #expect(out.last?.id == 4999)
        #expect(b.drain().isEmpty)
    }

    @Test func bufferCountsMultibyteText() {
        let b = LogBuffer(cap: 10_000, byteCap: 1000)
        let wide = (0..<20).map { _ in LogLine(id: 0, time: "", text: String(repeating: "é", count: 50), stderr: false) }
        _ = b.push(wide, lastTimestamp: nil)                                        // 100 bytes each
        #expect(b.drain().count == 10)
    }

    @Test @MainActor func storeTrimsToTheByteBudget() {
        let store = LogStore(api: DockerAPI(socketPath: "/nonexistent"), containerID: "c", name: "n",
                             maxLines: 100_000, maxBytes: 16_000)
        let b = LogBuffer(cap: 100_000, byteCap: 1 << 30)
        _ = b.push(lines(160, size: 100), lastTimestamp: nil)
        store.ingest(b.drain())
        #expect(store.lines.count == 160)                       // at the budget: no trim
        _ = b.push(lines(10, size: 100), lastTimestamp: nil)     // within the slack (1/16)
        store.ingest(b.drain())
        #expect(store.lines.count == 170)
        store.search = "x"
        _ = b.push(lines(1, size: 100), lastTimestamp: nil)
        store.ingest(b.drain())
        #expect(store.lines.count == 160)
        #expect(store.lines.reduce(0) { $0 + $1.text.utf8.count } <= 16_000)
        let first = store.lines.first!.id
        #expect(store.visible.map(\.id) == store.lines.map(\.id))
        #expect(store.visible.allSatisfy { $0.id >= first })
        // Clear starts the count again.
        store.clear()
        _ = b.push(lines(160, size: 100), lastTimestamp: nil)
        store.ingest(b.drain())
        #expect(store.lines.count == 160)
    }
}

@Suite struct CaseInsensitiveScanTests {
    private func has(_ text: String, _ query: String) -> Bool {
        var m = LogFilter.Matcher(query: query)
        return m.matches(text)
    }

    /// What the filter did before: lower-case both sides, then compare bytes.
    private func old(_ text: String, _ query: String) -> Bool {
        let n = Array(query.lowercased().utf8)
        return n.isEmpty || Array(text.lowercased().utf8).withUnsafeBufferPointer { h in
            n.withUnsafeBufferPointer { memmem(h.baseAddress, h.count, $0.baseAddress, $0.count) != nil }
        }
    }

    @Test func foldsASCIIOnTheRawText() {
        #expect(has("Connection REFUSED by Upstream", "refused"))
        #expect(has("Connection REFUSED by Upstream", "UPSTREAM"))
        #expect(has("[@`{] brackets", "[@`{]"))           // bytes next to A-Z and a-z do not fold
        #expect(!has("[@`{]", "{`@["))
        #expect(!has("abc", "abd"))
    }

    @Test func nonASCIIMatchesAsBefore() {
        #expect(has("ÄPFEL und Birnen", "äpfel"))
        #expect(has("äpfel", "ÄPFEL"))
        #expect(has("Grüße aus KÖLN", "köln"))
        #expect(has("Fehler: Datei FEHLT – Größe 0", "größe 0"))
        #expect(has("日本語のログ 🚀 DONE", "🚀 done"))
        #expect(!has("Grüße", "GRÜSSE"))                   // no full case folding, as before
        #expect(!has("Köln", "koln"))
        #expect(!has("ÁRBOL", "árboles"))
    }

    @Test func scratchFromALongLineDoesNotLeak() {
        var m = LogFilter.Matcher(query: "needle")
        let got = [String(repeating: "x", count: 5000) + "NEEDLE", "need", "xneedl", "a needle"].map { m.matches($0) }
        #expect(got == [true, false, false, true])
    }

    @Test func matchesTheOldFilterOnRandomText() {
        let alphabet = Array("aAbBzZ09 _-:[`{@ÄäÖößé🚀")
        var rng = SystemRandomNumberGenerator()
        func word(_ n: Int) -> String { String((0..<n).map { _ in alphabet.randomElement(using: &rng)! }) }
        for _ in 0..<3000 {
            let text = word(Int.random(in: 0...40, using: &rng))
            let query = Bool.random(using: &rng) && text.count > 2
                ? String(text.dropFirst(Int.random(in: 0...2, using: &rng)).prefix(Int.random(in: 1...6, using: &rng))).uppercased()
                : word(Int.random(in: 1...3, using: &rng))
            #expect(has(text, query) == old(text, query), "\(text) / \(query)")
        }
    }

    @Test func filtersTwentyThousandLinesQuickly() {
        let lines = (0..<20_000).map { "2026-10-06 INFO worker-\($0 % 64) handled GET /api/v1/items/\($0) in \($0 % 900) ms" }
        var m = LogFilter.Matcher(query: "ERROR timeout")
        // The best of 5 runs, so other suites running in parallel do not count.
        var best = Duration.seconds(60)
        var hits = 0
        for _ in 0..<5 {
            let start = ContinuousClock.now
            hits = 0
            for l in lines where m.matches(l) { hits += 1 }
            best = min(best, ContinuousClock.now - start)
        }
        #expect(hits == 0)
        // About 0.9 ms in a release build (the same as the old filter on a
        // stored lower-case copy) and 5-15 ms in a debug build. The bound is
        // generous, so slow CI under load does not fail.
        #expect(best < .seconds(1), "\(best)")
    }
}

@Suite struct LogSinceFromAttemptTests {
    private let base = "follow=1&stdout=1&stderr=1&timestamps=1"

    @Test func usesTheLastLineFirst() {
        let q = LogStore.logQuery(lastTimestamp: "1970-01-01T00:00:10.5Z", lastStart: Date(timeIntervalSince1970: 99), tail: 0)
        #expect(q == base + "&tail=all&since=10.500000001")
    }

    @Test func usesThePreviousAttemptWhenNoLineArrived() {
        let q = LogStore.logQuery(lastTimestamp: nil, lastStart: Date(timeIntervalSince1970: 1_700_000_000.5), tail: 0)
        #expect(q == base + "&tail=all&since=1700000000.500000000")
    }

    @Test func firstAttemptUsesTail() {
        #expect(LogStore.logQuery(lastTimestamp: nil, lastStart: nil, tail: 1000) == base + "&tail=1000")
        #expect(LogStore.logQuery(lastTimestamp: nil, lastStart: nil, tail: 0) == base + "&tail=0")
    }

    @Test func formatsDatesAndParsesTheHTTPDate() {
        #expect(LogStore.sinceParam(date: Date(timeIntervalSince1970: 42)) == "42.000000000")
        #expect(LogStore.sinceParam(date: Date(timeIntervalSince1970: 0.25)) == "0.250000000")
        let d = LogStore.httpDate("Tue, 06 Oct 2026 10:00:00 GMT")
        #expect(d == LogTime.parse("2026-10-06T10:00:00Z").map { Date(timeIntervalSince1970: TimeInterval($0.secs)) })
        #expect(LogStore.httpDate("not a date") == nil)
    }
}
