import Foundation
import Testing
@testable import ColimaBar

@Suite struct LogTimeTests {
    /// The reference value comes from Foundation, which the app used before.
    private func epoch(_ s: String) -> Int64 {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return Int64(f.date(from: s)!.timeIntervalSince1970)
    }

    @Test func parsesZeroThreeSixAndNineFractionalDigits() {
        let secs = epoch("2026-10-02T14:03:11Z")
        #expect(LogTime.parse("2026-10-02T14:03:11Z")! == (secs, 0))
        #expect(LogTime.parse("2026-10-02T14:03:11.123Z")! == (secs, 123_000_000))
        #expect(LogTime.parse("2026-10-02T14:03:11.123456Z")! == (secs, 123_456_000))
        #expect(LogTime.parse("2026-10-02T14:03:11.123456789Z")! == (secs, 123_456_789))
    }

    @Test func matchesFoundationOverManyDates() {
        // Covers leap years, month ends and both sides of 1970.
        for s in ["1970-01-01T00:00:00Z", "1969-12-31T23:59:59Z", "2000-02-29T12:00:00Z",
                  "2024-12-31T23:59:59Z", "2100-03-01T00:00:00Z", "2038-01-19T03:14:08Z"] {
            #expect(LogTime.parse(Substring(s))?.secs == epoch(s), "\(s)")
        }
    }

    @Test func acceptsZoneOffsetsAndLowerCase() {
        let secs = epoch("2026-10-02T12:03:11Z")
        #expect(LogTime.parse("2026-10-02T14:03:11+02:00")?.secs == secs)
        #expect(LogTime.parse("2026-10-02T09:33:11.5-02:30")! == (secs, 500_000_000))
        #expect(LogTime.parse("2026-10-02t12:03:11z")?.secs == secs)
    }

    @Test func cutsDigitsPastNine() {
        #expect(LogTime.parse("1970-01-01T00:00:01.1234567891Z")! == (1, 123_456_789))
    }

    @Test func rejectsInvalidTimestamps() {
        for s in ["", "nope", "2026-10-02T14:03:11", "2026-10-02T14:03:11.Z", "2026-02-30T00:00:00Z",
                  "2026-13-01T00:00:00Z", "2026-10-02T24:00:00Z", "2026-10-02 14:03:11Z",
                  "2026-10-02T14:03:11Zjunk", "2026-10-02T14:03:11+0200", "404 not found"] {
            #expect(LogTime.parse(Substring(s)) == nil, "\(s)")
        }
    }

    @Test func sinceKeepsNanosecondPrecision() {
        let secs = epoch("2026-10-02T14:03:11Z")
        #expect(LogStore.sinceParam("2026-10-02T14:03:11.123456789Z") == "\(secs).123456790")
        #expect(LogStore.sinceParam("2026-10-02T14:03:11.000000001Z") == "\(secs).000000002")
    }

    @Test func clockMatchesDateFormatterInLocalTime() {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        // Half a year apart, so one of them is in daylight saving time
        // where the local zone has it.
        let cases = [("2026-01-15T08:09:10.987654321Z", ".987"), ("2026-07-15T23:59:59.001Z", ".001"),
                     ("2026-03-29T01:30:00Z", ".000")]
        for (s, ms) in cases {
            let t = LogTime.parse(Substring(s))!
            let date = Date(timeIntervalSince1970: TimeInterval(t.secs))
            #expect(LogTime.clock(secs: t.secs, nanos: t.nanos) == f.string(from: date) + ms, "\(s)")
        }
    }

    @Test func lineParseSplitsTimestampFromText() {
        let p = LogLine.parse("2026-10-02T14:03:11.123456789Z GET /health 200", stderr: true)
        #expect(p.timestamp == "2026-10-02T14:03:11.123456789Z")
        #expect(p.line.text == "GET /health 200")
        #expect(p.line.time.hasSuffix("11.123"))
        #expect(p.line.stderr)
    }

    @Test func lineWithoutTimestampKeepsAllText() {
        let p = LogLine.parse("404 Not Found", stderr: false)
        #expect(p.timestamp == nil)
        #expect(p.line.text == "404 Not Found")
        #expect(p.line.time == "")
    }

    @Test func twentyThousandLinesParseQuickly() {
        let raw = (0..<20_000).map { "2026-10-02T14:03:11.\(String(format: "%09d", $0))Z Line \($0) with Some TEXT" }
        let start = ContinuousClock.now
        var last: Substring?
        for r in raw { last = LogLine.parse(r, stderr: false).timestamp }
        let elapsed = ContinuousClock.now - start
        #expect(last != nil)
        // About 60 ms in a debug build on Apple silicon. The old formatter
        // needed about 1 s. The bound is generous, so slow CI does not fail.
        #expect(elapsed < .milliseconds(500), "\(elapsed)")
    }
}

@Suite struct LogFilterTests {
    private func has(_ text: String, _ query: String) -> Bool {
        LogFilter.contains(text, LogFilter.needle(query))
    }

    @Test func asciiIsCaseInsensitive() {
        #expect(has("Connection REFUSED by upstream", "refused"))
        #expect(has("connection refused", "REFUSED"))
        #expect(has("short", "SHORT"))
        #expect(!has("connection refused", "accepted"))
    }

    @Test func nonASCIIText() {
        #expect(has("Grüße aus Köln ✓", "GRÜSSE") == false)   // no full case folding
        #expect(has("Grüße aus Köln ✓", "KÖLN"))
        #expect(has("ÄPFEL und Birnen", "äpfel"))
        #expect(has("日本語のログ 🚀 done", "🚀 DONE"))
        #expect(!has("Köln", "koln"))
    }

    @Test func edgeCases() {
        #expect(has("anything", ""))
        #expect(has("", ""))
        #expect(!has("", "a"))
        #expect(!has("ab", "abc"))
        #expect(has(String(repeating: "x", count: 10_000) + "Needle", "needle"))
    }

    @Test @MainActor func storeFiltersBySearchAndStderr() {
        let store = LogStore(api: DockerAPI(socketPath: "/nonexistent"), containerID: "c", name: "n")
        let b = LogBuffer(cap: 100)
        _ = b.push([LogLine(id: 0, time: "", text: "Error: disk full", stderr: true),
                    LogLine(id: 0, time: "", text: "all good", stderr: false),
                    LogLine(id: 0, time: "", text: "another ERROR", stderr: false)], lastTimestamp: nil)
        store.ingest(b.drain())
        store.search = "error"
        #expect(store.visible.map(\.text) == ["Error: disk full", "another ERROR"])
        store.stderrOnly = true
        #expect(store.visible.map(\.text) == ["Error: disk full"])
        store.search = ""
        store.stderrOnly = false
        #expect(store.visible.count == 3)
    }
}

@Suite struct LogCapTests {
    private func lines(_ n: Int) -> [LogLine] {
        (0..<n).map { LogLine(id: 0, time: "", text: "line \($0)", stderr: false) }
    }

    @Test func bufferKeepsNewestLinesUpToCap() {
        let b = LogBuffer(cap: 100)
        for _ in 0..<50 { _ = b.push(lines(100), lastTimestamp: nil) }
        let out = b.drain()
        #expect(out.count == 100)
        #expect(out.map(\.id) == Array(4900..<5000))
        #expect(b.drain().isEmpty)
    }

    @Test func bufferAsksForOneFlushUntilDrained() {
        let b = LogBuffer(cap: 100)
        #expect(b.push(lines(1), lastTimestamp: "t1"))
        #expect(!b.push(lines(1), lastTimestamp: nil))
        #expect(b.lastTimestamp == "t1")
        _ = b.drain()
        #expect(!b.push([], lastTimestamp: nil))
        #expect(b.push(lines(1), lastTimestamp: "t2"))
        #expect(b.lastTimestamp == "t2")
    }

    @Test @MainActor func storeTrimsInBatches() {
        let store = LogStore(api: DockerAPI(socketPath: "/nonexistent"), containerID: "c", name: "n", maxLines: 100)
        let b = LogBuffer(cap: 10_000)
        _ = b.push(lines(100 + LogStore.trimSlack), lastTimestamp: nil)
        store.ingest(b.drain())
        #expect(store.lines.count == 100 + LogStore.trimSlack)     // within the slack: no trim yet
        store.search = "line 2"
        _ = b.push(lines(1), lastTimestamp: nil)
        store.ingest(b.drain())
        #expect(store.lines.count == 100)
        #expect(store.lines.last?.id == 100 + LogStore.trimSlack)
        // Visible lines older than the first kept line are gone too.
        let first = store.lines.first!.id
        #expect(store.visible.allSatisfy { $0.id >= first })
        #expect(store.visible.map(\.id) == store.lines.filter { $0.text.contains("line 2") }.map(\.id))
    }
}

@Suite struct LogLongLineTests {
    private let max = LogDemuxer.maxLineBytes
    private let marker = LogDemuxer.splitMarker

    @Test func splitsLongLineWithoutNewline() {
        var d = LogDemuxer(tty: true)
        let text = String(repeating: "a", count: max * 2 + 100)
        let first = d.feed(Data(text.utf8))
        #expect(first.count == 2)
        #expect(first.allSatisfy { $0.0 == String(repeating: "a", count: max) + marker })
        // The rest waits for its newline.
        #expect(d.feed(Data("\n".utf8)).map(\.0) == [String(repeating: "a", count: 100)])
    }

    @Test func splitsLongCompleteLine() {
        var d = LogDemuxer(tty: true)
        let out = d.feed(Data((String(repeating: "b", count: max + 5) + "\nnext\n").utf8))
        #expect(out.map(\.0) == [String(repeating: "b", count: max) + marker, "bbbbb", "next"])
    }

    @Test func doesNotCutMultibyteCharacters() {
        var d = LogDemuxer(tty: false)
        let text = String(repeating: "é", count: max) + "\n"     // 2 bytes each
        var frame = Data([1, 0, 0, 0, 0, 0, 0, 0])
        let payload = Data(text.utf8)
        frame[4] = UInt8(payload.count >> 24); frame[5] = UInt8(payload.count >> 16 & 0xff)
        frame[6] = UInt8(payload.count >> 8 & 0xff); frame[7] = UInt8(payload.count & 0xff)
        let out = d.feed(frame + payload)
        #expect(out.count == 2)
        #expect(out.allSatisfy { !$0.0.contains("\u{FFFD}") })
        let joined = out.map { $0.0.replacingOccurrences(of: marker, with: "") }.joined()
        #expect(joined == String(repeating: "é", count: max))
    }

    @Test func manyFramesInOneReadStayInOrder() {
        var d = LogDemuxer(tty: false)
        var data = Data()
        for i in 0..<1000 {
            let p = Data("line \(i)\n".utf8)
            data += Data([i % 2 == 0 ? 1 : 2, 0, 0, 0, 0, 0, 0, UInt8(p.count)]) + p
        }
        let out = d.feed(data.prefix(5000))
        let rest = d.feed(data.dropFirst(5000))
        let all = out + rest
        #expect(all.map(\.0) == (0..<1000).map { "line \($0)" })
        #expect(all.map(\.1) == (0..<1000).map { $0 % 2 == 1 })
    }
}
