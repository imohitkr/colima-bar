import Foundation
import Testing

@testable import ColimaBar

@Suite struct LogLineTests {
    @Test func lineParseSplitsTimestampFromText() {
        let p = LogLine.parse("2026-10-02T14:03:11.123456789Z GET /health 200", isStderr: true)
        #expect(p.timestamp == "2026-10-02T14:03:11.123456789Z")
        #expect(p.line.text == "GET /health 200")
        #expect(p.line.time.hasSuffix("11.123"))
        #expect(p.line.isStderr)
    }

    @Test func lineWithoutTimestampKeepsAllText() {
        let p = LogLine.parse("404 Not Found", isStderr: false)
        #expect(p.timestamp == nil)
        #expect(p.line.text == "404 Not Found")
        #expect(p.line.time == "")
    }

    @Test func twentyThousandLinesParseQuickly() {
        let raw = (0..<20_000).map { "2026-10-02T14:03:11.\(String(format: "%09d", $0))Z Line \($0) with Some TEXT" }
        var last: Substring?
        let best = bestTime {
            for r in raw { last = LogLine.parse(r, isStderr: false).timestamp }
        }
        #expect(last != nil)
        // About 60 ms in a debug build on Apple silicon. The old formatter
        // needed about 1 s. The best of 3 runs keeps the bound stable while
        // other suites run in parallel.
        #expect(best < .milliseconds(500), "\(best)")
    }
}
