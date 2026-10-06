import CoreGraphics
import Foundation
import Testing
@testable import ColimaBar

@Suite struct LogTailTests {
    @Test func rendersAllLinesUpToLimitPlusSlack() {
        #expect(LogTail.start(current: 0, count: 0, limit: 10, slack: 5) == 0)
        #expect(LogTail.start(current: 0, count: 15, limit: 10, slack: 5) == 0)
        // One line more: the oldest leave as a batch, `limit` stay.
        #expect(LogTail.start(current: 0, count: 16, limit: 10, slack: 5) == 6)
    }

    @Test func keepsTheStartUntilTheSlackIsUsed() {
        #expect(LogTail.start(current: 6, count: 20, limit: 10, slack: 5) == 6)
        #expect(LogTail.start(current: 6, count: 22, limit: 10, slack: 5) == 12)
        // A big batch jumps straight to the newest `limit` lines.
        #expect(LogTail.start(current: 6, count: 1000, limit: 10, slack: 5) == 990)
    }

    @Test func clampsAStartOutsideTheLines() {
        #expect(LogTail.start(current: -3, count: 5, limit: 10, slack: 5) == 0)
        #expect(LogTail.start(current: 50, count: 5, limit: 10, slack: 5) == 5)
        #expect(LogTail.reset(count: 5, limit: 10) == 0)
        #expect(LogTail.reset(count: 25, limit: 10) == 15)
    }
}

@Suite @MainActor struct LogStoreTailTests {
    private func lines(_ n: Int, err: (Int) -> Bool = { _ in false }) -> [LogLine] {
        (0..<n).map { LogLine(id: 0, time: "", text: "line \($0)", stderr: err($0)) }
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
        #expect(s.shown.allSatisfy { $0.stderr })
        #expect(s.shown.last?.id == 8999 - 8999 % 3)
        s.search = "line 99"
        // "line 99", "line 990".."line 999" and "line 9900".."line 9999" (none past 8999).
        #expect(s.tailStart == 0)
        #expect(s.shown.map(\.text) == s.visible.map(\.text))
        #expect(s.shown.allSatisfy { $0.stderr && $0.text.hasPrefix("line 99") })
        s.search = ""
        s.stderrOnly = false
        #expect(s.tailStart == 9000 - LogTail.limit)
    }

    @Test func headTrimMovesTheTailStartWithTheLines() {
        let s = store(maxLines: 3000)
        let b = LogBuffer(cap: 100_000)
        s.follow = false
        ingest(s, b, lines(3000 + LogStore.trimSlack))
        #expect(s.tailStart == s.visible.count - LogTail.limit)
        ingest(s, b, lines(1))     // past the slack: the store drops old lines
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
}

@Suite struct SparklineTests {
    private let r = CGRect(x: 0, y: 0, width: 59, height: 30)

    @Test func noLineForFewerThanTwoSamples() {
        #expect(Sparkline.points([], in: r).isEmpty)
        #expect(Sparkline.points([42], in: r).isEmpty)
        #expect(Sparkline(values: []).path(in: r).isEmpty)
        #expect(Sparkline(values: [42], area: true).path(in: r).isEmpty)
    }

    @Test func scalesToZeroToHundred() {
        let pts = Sparkline.points([0, 50, 100], in: r)
        #expect(pts == [CGPoint(x: 0, y: 30), CGPoint(x: 1, y: 15), CGPoint(x: 2, y: 0)])
    }

    @Test func sixtySamplesSpanTheWidth() {
        let pts = Sparkline.points(Array(repeating: 25, count: 60), in: CGRect(x: 10, y: 5, width: 118, height: 40))
        #expect(pts.first == CGPoint(x: 10, y: 35))
        #expect(pts.last == CGPoint(x: 128, y: 35))
    }

    @Test func valuesAboveHundredRaiseTheTop() {
        let pts = Sparkline.points([0, 200], in: r)
        #expect(pts.map(\.y) == [30, 0])
    }

    @Test func areaClosesDownToTheBottom() {
        let line = Sparkline(values: [10, 20, 30]).path(in: r)
        let area = Sparkline(values: [10, 20, 30], area: true).path(in: r)
        #expect(line.boundingRect.maxY < 30)
        #expect(area.boundingRect.maxY == 30)
        #expect(area.boundingRect.minX == 0 && area.boundingRect.maxX == 2)
    }
}

@Suite struct BufferSizeTests {
    @Test func copyBuffersAre16KB() {
        #expect(SocketProxy.bufferSize == 16 * 1024)
        #expect(DockerAPI.bufferSize == 16 * 1024)
        // The VM-down path reads a request head in pieces, up to maxHead.
        #expect(SocketProxy.maxHead >= SocketProxy.bufferSize)
    }
}
