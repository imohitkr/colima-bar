import Foundation
import Testing

@testable import ColimaBar

@Suite struct LogBufferTests {
    private func lines(_ n: Int) -> [LogLine] {
        (0..<n).map { LogLine(id: 0, time: "", text: "line \($0)", stderr: false) }
    }

    private func lines(_ n: Int, size: Int) -> [LogLine] {
        (0..<n).map { i in
            LogLine(
                id: 0, time: "", text: String(format: "%05d", i) + String(repeating: "x", count: size - 5),
                stderr: false)
        }
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

    @Test func bufferKeepsNewestLinesWithinTheByteBudget() {
        let b = LogBuffer(cap: 10_000, byteCap: 10_000)
        for _ in 0..<50 { _ = b.push(lines(100, size: 100), lastTimestamp: nil) }  // 500 kB pushed
        let out = b.drain()
        #expect(out.count == 100)
        #expect(out.reduce(0) { $0 + $1.text.utf8.count } <= 10_000)
        #expect(out.last?.id == 4999)
        #expect(b.drain().isEmpty)
    }

    @Test func bufferCountsMultibyteText() {
        let b = LogBuffer(cap: 10_000, byteCap: 1000)
        let wide = (0..<20).map { _ in LogLine(id: 0, time: "", text: String(repeating: "é", count: 50), stderr: false)
        }
        _ = b.push(wide, lastTimestamp: nil)  // 100 bytes each
        #expect(b.drain().count == 10)
    }
}
