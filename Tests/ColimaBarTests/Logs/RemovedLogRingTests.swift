import Foundation
import Testing

@testable import ColimaBar

@Suite struct RemovedLogRingTests {
    /// One stdout frame for each line "line N", without timestamps.
    private func frames(_ n: Int, from start: Int = 0) -> Data {
        (start..<(start + n)).reduce(into: Data()) { $0 += LogFrame.make(1, "line \($1)\n") }
    }

    /// Feeds `data` in reads of `size` bytes, so frames split across reads.
    private func feed(_ r: RemovedLogRing, _ data: Data, in size: Int) {
        var i = data.startIndex
        while i < data.endIndex {
            let end = min(i + size, data.endIndex)
            r.feed(data[i..<end])
            i = end
        }
    }

    @Test func returnsOnlyTheNewestLines() {
        let r = RemovedLogRing(maxLines: RemovedLogKeeper.maxLines, maxBytes: 1 << 20)
        r.feed(frames(450))
        r.feed(frames(150, from: 450))
        let kept = r.lines()
        #expect(kept.count == 500)
        #expect(kept.first?.text == "line 100")
        #expect(kept.last?.text == "line 599")
        #expect(zip(kept, kept.dropFirst()).allSatisfy { $0.id < $1.id })
    }

    @Test func keepsAtMostItsBytesAndDropsWholeFrames() {
        // Each frame is 8 header bytes and "line NN\n": 16 bytes.
        let r = RemovedLogRing(maxLines: 500, maxBytes: 100)
        feed(r, frames(90, from: 10), in: 7)
        #expect(r.rawBytes <= 100)
        // 100 bytes hold 6 frames of 16 bytes. All lines are whole.
        #expect(r.lines().map(\.text) == (94..<100).map { "line \($0)" })
    }

    @Test func wrapsAroundWithoutLosingOrder() {
        let r = RemovedLogRing(maxLines: 500, maxBytes: 1000)
        for start in stride(from: 100, to: 1000, by: 37) {
            feed(r, frames(37, from: start), in: 13)
            let texts = r.lines().map(\.text)
            let last = start + 36
            #expect(texts.last == "line \(last)")
            #expect(texts == ((last - texts.count + 1)...last).map { "line \($0)" })
        }
    }

    @Test func dropsAFrameLargerThanTheRing() {
        let r = RemovedLogRing(maxLines: 500, maxBytes: 64)
        r.feed(frames(1, from: 10))
        let big = LogFrame.make(1, String(repeating: "x", count: 200) + "\n")
        // The large frame arrives in three reads; then a normal one follows.
        feed(r, big, in: 90)
        r.feed(frames(1, from: 11))
        #expect(r.lines().map(\.text) == ["line 11"])
    }

    @Test func parsesNothingUntilTheLinesAreRead() {
        let r = RemovedLogRing(maxLines: 500, maxBytes: 1 << 20)
        let data = LogFrame.make(1, "2026-10-07T10:00:00.000000001Z starting\n")
        r.feed(data)
        // The ring holds the raw frame, header and timestamp included.
        #expect(r.rawBytes == data.count)
    }

    @Test func linesSplitFramesAndParseTimestamps() {
        let r = RemovedLogRing(maxLines: 500, maxBytes: 1 << 20)
        r.feed(LogFrame.make(1, "2026-10-07T10:00:00.000000001Z starting\n2026-10-07T10:00:01.0Z rea"))
        r.feed(LogFrame.make(1, "dy\n") + LogFrame.make(2, "2026-10-07T10:00:02.5Z panic: boom\n"))
        let kept = r.lines()
        #expect(kept.map(\.text) == ["starting", "ready", "panic: boom"])
        #expect(kept.map(\.isStderr) == [false, false, true])
        #expect(kept.allSatisfy { !$0.time.isEmpty })
    }

    @Test func ttyStreamIsRawText() {
        let r = RemovedLogRing(maxLines: 500, maxBytes: 1 << 20)
        r.setTTY(true)
        r.feed(Data("2026-10-07T10:00:00Z one\r\n2026-10-07T10:00:01Z two\n".utf8))
        #expect(r.lines().map(\.text) == ["one", "two"])
    }

    @Test func ttyStreamLeavesOutTheLineThatADropCut() {
        let r = RemovedLogRing(maxLines: 500, maxBytes: 12)
        r.setTTY(true)
        r.feed(Data("first\nsecond\nthird\n".utf8))
        // 12 bytes keep "econd\nthird\n": "econd" lost its start.
        #expect(r.lines().map(\.text) == ["third"])
        // This drop ends at a line break ("econd\n"), so it cuts no line.
        r.feed(Data("fifth\n".utf8))
        #expect(r.lines().map(\.text) == ["third", "fifth"])
    }

    @Test func leavesOutTheLineThatADropCutInItsStream() {
        // Frames of 8 header bytes: "ab" (no "\n"), "cd\n" and "ef\n" on
        // stdout, then "err\n" on stderr.
        let data =
            LogFrame.make(1, "ab") + LogFrame.make(1, "cd\n") + LogFrame.make(1, "ef\n") + LogFrame.make(2, "err\n")
        // The ring drops only the first frame: "cd" lost its start "ab".
        let r = RemovedLogRing(maxLines: 500, maxBytes: data.count - 10)
        r.feed(data)
        #expect(r.lines().map(\.text) == ["ef", "err"])
        // The next drop ends with a full line ("cd\n"): nothing is cut now.
        r.feed(LogFrame.make(1, "gh\n"))
        #expect(r.lines().map(\.text) == ["ef", "err", "gh"])
    }

    @Test func aCutInOneStreamKeepsTheOtherStream() {
        // A stderr frame without "\n" is dropped. The first stdout line stays.
        let data = LogFrame.make(2, "pa") + LogFrame.make(1, "out\n") + LogFrame.make(2, "nic\n")
        let r = RemovedLogRing(maxLines: 500, maxBytes: data.count - 10)
        r.feed(data)
        #expect(r.lines().map(\.text) == ["out"])
        #expect(r.lines().map(\.isStderr) == [false])
    }

    @Test func aSkippedLargeFrameCutsTheLineOnlyIfItEndsMidLine() {
        for (tail, expected) in [("\n", ["next"]), ("", [])] {
            let r = RemovedLogRing(maxLines: 500, maxBytes: 64)
            // The large frame arrives in reads of 30 bytes, then the rest of
            // its line arrives in a new frame.
            feed(r, LogFrame.make(1, String(repeating: "x", count: 200) + tail), in: 30)
            r.feed(LogFrame.make(1, "next\n"))
            #expect(r.lines().map(\.text) == expected, "tail \(tail.debugDescription)")
        }
    }

    @Test func keepsALastLineWithoutANewline() {
        let r = RemovedLogRing(maxLines: 500, maxBytes: 1 << 20)
        r.feed(LogFrame.make(1, "starting\n") + LogFrame.make(2, "2026-10-07T10:00:02.5Z fatal: boom"))
        let kept = r.lines()
        #expect(kept.map(\.text) == ["starting", "fatal: boom"])
        #expect(kept.map(\.isStderr) == [false, true])
        #expect(kept.map(\.id) == [0, 1])

        let tty = RemovedLogRing(maxLines: 500, maxBytes: 1 << 20)
        tty.setTTY(true)
        tty.feed(Data("one\ncrash without newline".utf8))
        #expect(tty.lines().map(\.text) == ["one", "crash without newline"])
    }
}
