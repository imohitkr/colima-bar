import Foundation
import Testing

@testable import ColimaBar

@Suite @MainActor struct LogStoreTests {
    private func lines(_ n: Int, err: (Int) -> Bool = { _ in false }) -> [LogLine] {
        (0..<n).map { LogLine(id: 0, time: "", text: "line \($0)", isStderr: err($0)) }
    }

    private func lines(_ n: Int, size: Int) -> [LogLine] {
        (0..<n).map { i in
            LogLine(
                id: 0, time: "", text: String(format: "%05d", i) + String(repeating: "x", count: size - 5),
                isStderr: false)
        }
    }

    private func store(maxLines: Int = 20_000) -> LogStore {
        LogStore(api: DockerAPI(socketPath: "/nonexistent"), containerID: "c", name: "n", maxLines: maxLines)
    }

    private func ingest(_ s: LogStore, _ b: LogBuffer, _ new: [LogLine]) {
        _ = b.push(new, lastTimestamp: nil)
        s.ingest(b.drain())
    }

    @Test func rendersOnlyTheNewestLines() {
        let s = store()
        let b = LogBuffer(cap: 100_000)
        ingest(s, b, lines(LogTail.limit))
        #expect(s.tailStart == 0)
        // With Follow on, the oldest rows leave with each batch.
        ingest(s, b, lines(1))
        #expect(s.tailStart == 1)
        #expect(s.shown.count == LogTail.limit)
        #expect(s.shown.last?.id == s.visible.last?.id)
        // Copy still takes every visible line, also the ones not rendered.
        #expect(s.allText.split(separator: "\n").count == s.visible.count)
    }

    @Test func followOffKeepsTheRowsUntilTheSlackIsUsed() {
        let s = store()
        let b = LogBuffer(cap: 100_000)
        ingest(s, b, lines(LogTail.limit + 10))
        #expect(s.tailStart == 10)
        s.follow = false
        ingest(s, b, lines(LogTail.slack))
        #expect(s.tailStart == 10)
        #expect(s.shown.count == LogTail.limit + LogTail.slack)
        ingest(s, b, lines(1))
        #expect(s.shown.count == LogTail.limit)
        #expect(s.shown.last?.id == s.visible.last?.id)
        // Follow on again drops the extra rows at once.
        ingest(s, b, lines(5))
        s.follow = true
        #expect(s.shown.count == LogTail.limit)
        #expect(s.shown.last?.id == s.visible.last?.id)
    }

    @Test func filterResetsTheTailToTheNewestMatches() {
        let s = store()
        let b = LogBuffer(cap: 100_000)
        // Every third line is stderr.
        ingest(s, b, lines(9000) { $0 % 3 == 0 })
        #expect(s.shown.count == LogTail.limit)
        s.stderrOnly = true
        #expect(s.visible.count == 3000)
        #expect(s.tailStart == 1000)
        #expect(s.shown.allSatisfy { $0.isStderr })
        #expect(s.shown.last?.id == 8999 - 8999 % 3)
        s.search = "line 99"
        // "line 99", "line 990".."line 999" and "line 9900".."line 9999" (none past 8999).
        #expect(s.tailStart == 0)
        #expect(s.shown.map(\.text) == s.visible.map(\.text))
        #expect(s.shown.allSatisfy { $0.isStderr && $0.text.hasPrefix("line 99") })
        s.search = ""
        s.stderrOnly = false
        #expect(s.tailStart == 9000 - LogTail.limit)
    }

    @Test func headTrimMovesTheTailStartWithTheLines() {
        let s = store(maxLines: 3000)
        let b = LogBuffer(cap: 100_000)
        s.follow = false
        ingest(s, b, lines(3000 + LogLimits.trimSlack))
        #expect(s.tailStart == s.visible.count - LogTail.limit)
        ingest(s, b, lines(1))  // past the slack: the store drops old lines
        #expect(s.lines.count == 3000)
        #expect(s.shown.count <= LogTail.limit + LogTail.slack)
        #expect(s.shown.last?.id == s.lines.last?.id)
        #expect(s.tailStart >= 0 && s.tailStart <= s.visible.count)
        // The rendered lines are still a contiguous tail of `visible`.
        #expect(Array(s.shown.map(\.id)) == Array(s.visible.suffix(s.shown.count).map(\.id)))
    }

    @Test func clearRendersFromTheStart() {
        let s = store()
        let b = LogBuffer(cap: 100_000)
        ingest(s, b, lines(5000))
        #expect(s.tailStart > 0)
        s.clear()
        #expect(s.tailStart == 0)
        #expect(s.shown.isEmpty)
        ingest(s, b, lines(3))
        #expect(s.shown.count == 3)
    }

    @Test @MainActor func filtersBySearchAndStderr() {
        let store = LogStore(api: DockerAPI(socketPath: "/nonexistent"), containerID: "c", name: "n")
        let b = LogBuffer(cap: 100)
        _ = b.push(
            [
                LogLine(id: 0, time: "", text: "Error: disk full", isStderr: true),
                LogLine(id: 0, time: "", text: "all good", isStderr: false),
                LogLine(id: 0, time: "", text: "another ERROR", isStderr: false),
            ], lastTimestamp: nil)
        store.ingest(b.drain())
        store.search = "error"
        #expect(store.visible.map(\.text) == ["Error: disk full", "another ERROR"])
        store.stderrOnly = true
        #expect(store.visible.map(\.text) == ["Error: disk full"])
        store.search = ""
        store.stderrOnly = false
        #expect(store.visible.count == 3)
    }

    @Test @MainActor func trimsInBatches() {
        let store = LogStore(api: DockerAPI(socketPath: "/nonexistent"), containerID: "c", name: "n", maxLines: 100)
        let b = LogBuffer(cap: 10_000)
        _ = b.push(lines(100 + LogLimits.trimSlack), lastTimestamp: nil)
        store.ingest(b.drain())
        #expect(store.lines.count == 100 + LogLimits.trimSlack)  // within the slack: no trim yet
        store.search = "line 2"
        _ = b.push(lines(1), lastTimestamp: nil)
        store.ingest(b.drain())
        #expect(store.lines.count == 100)
        #expect(store.lines.last?.id == 100 + LogLimits.trimSlack)
        // Visible lines older than the first kept line are gone too.
        let first = store.lines.first!.id
        #expect(store.visible.allSatisfy { $0.id >= first })
        #expect(store.visible.map(\.id) == store.lines.filter { $0.text.contains("line 2") }.map(\.id))
    }

    @Test @MainActor func trimsToTheByteBudget() {
        let store = LogStore(
            api: DockerAPI(socketPath: "/nonexistent"), containerID: "c", name: "n",
            maxLines: 100_000, maxBytes: 16_000)
        let b = LogBuffer(cap: 100_000, byteCap: 1 << 30)
        _ = b.push(lines(160, size: 100), lastTimestamp: nil)
        store.ingest(b.drain())
        #expect(store.lines.count == 160)  // at the budget: no trim
        _ = b.push(lines(10, size: 100), lastTimestamp: nil)  // within the slack (1/16)
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

    /// The `since` and query parameters of the logs request.
    @Suite struct Query {
        private let base = "follow=1&stdout=1&stderr=1&timestamps=1"

        /// The reference value comes from Foundation, which the app used before.
        private func epoch(_ s: String) -> Int64 {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime]
            return Int64(f.date(from: s)!.timeIntervalSince1970)
        }

        @Test func sinceKeepsNanosecondPrecision() {
            let secs = epoch("2026-10-02T14:03:11Z")
            #expect(LogStore.sinceParam("2026-10-02T14:03:11.123456789Z") == "\(secs).123456790")
            #expect(LogStore.sinceParam("2026-10-02T14:03:11.000000001Z") == "\(secs).000000002")
        }

        @Test @MainActor func convertsRFC3339ToUnixNanosPlusOne() {
            #expect(LogStore.sinceParam("1970-01-01T00:00:10.000000005Z") == "10.000000006")
            #expect(LogStore.sinceParam("1970-01-01T00:00:10.5Z") == "10.500000001")
        }

        @Test @MainActor func carriesIntoSeconds() {
            #expect(LogStore.sinceParam("1970-01-01T00:00:10.999999999Z") == "11.000000000")
        }

        @Test @MainActor func handlesMissingFraction() {
            #expect(LogStore.sinceParam("1970-01-01T00:01:00Z") == "60.000000001")
        }

        @Test @MainActor func rejectsGarbage() {
            #expect(LogStore.sinceParam("nope") == nil)
        }

        @Test func usesTheLastLineFirst() {
            let q = LogStore.logQuery(
                lastTimestamp: "1970-01-01T00:00:10.5Z", lastStart: Date(timeIntervalSince1970: 99), tail: 0)
            #expect(q == base + "&tail=all&since=10.500000001")
        }

        @Test func usesThePreviousAttemptWhenNoLineArrived() {
            let q = LogStore.logQuery(
                lastTimestamp: nil, lastStart: Date(timeIntervalSince1970: 1_700_000_000.5), tail: 0)
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
            #expect(
                d == LogTime.parse("2026-10-06T10:00:00Z").map { Date(timeIntervalSince1970: TimeInterval($0.secs)) })
            #expect(LogStore.httpDate("not a date") == nil)
        }
    }
}
