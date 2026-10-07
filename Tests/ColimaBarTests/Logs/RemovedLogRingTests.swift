import Foundation
import Testing

@testable import ColimaBar

@Suite struct RemovedLogRingTests {
    private func lines(_ n: Int, from start: Int = 0) -> [LogLine] {
        (start..<(start + n)).map { LogLine(id: 0, time: "", text: "line \($0)", isStderr: false) }
    }

    @Test func keepsOnlyTheNewestLines() {
        let r = RemovedLogRing(maxLines: RemovedLogKeeper.maxLines, maxBytes: 1 << 20)
        r.push(lines(450))
        r.push(lines(150, from: 450))
        let kept = r.snapshot
        #expect(kept.count == 500)
        #expect(kept.first?.text == "line 100")
        #expect(kept.last?.text == "line 599")
        // The ids keep the order, also across pushes.
        #expect(zip(kept, kept.dropFirst()).allSatisfy { $0.id < $1.id })
    }

    @Test func keepsAtMostItsBytes() {
        let r = RemovedLogRing(maxLines: 500, maxBytes: 100)
        let ten = String(repeating: "x", count: 10)
        r.push((0..<30).map { _ in LogLine(id: 0, time: "", text: ten, isStderr: false) })
        #expect(r.snapshot.count == 10)
        #expect(r.textBytes == 100)
        // One long line pushes out older ones.
        r.push([LogLine(id: 0, time: "", text: String(repeating: "y", count: 95), isStderr: false)])
        #expect(r.snapshot.count == 1)
        #expect(r.textBytes == 95)
    }

    @Test func feedSplitsFramesAndParsesTimestamps() {
        let r = RemovedLogRing(maxLines: 500, maxBytes: 1 << 20)
        r.feed(LogFrame.make(1, "2026-10-07T10:00:00.000000001Z starting\n2026-10-07T10:00:01.0Z rea"))
        r.feed(LogFrame.make(1, "dy\n") + LogFrame.make(2, "2026-10-07T10:00:02.5Z panic: boom\n"))
        let kept = r.snapshot
        #expect(kept.map(\.text) == ["starting", "ready", "panic: boom"])
        #expect(kept.map(\.isStderr) == [false, false, true])
        #expect(kept.allSatisfy { !$0.time.isEmpty })
    }

    @Test func ttyStreamIsRawText() {
        let r = RemovedLogRing(maxLines: 500, maxBytes: 1 << 20)
        r.setTTY(true)
        r.feed(Data("2026-10-07T10:00:00Z one\r\n2026-10-07T10:00:01Z two\n".utf8))
        #expect(r.snapshot.map(\.text) == ["one", "two"])
    }
}
