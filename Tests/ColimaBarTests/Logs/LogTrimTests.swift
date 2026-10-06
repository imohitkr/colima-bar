import Foundation
import Testing

@testable import ColimaBar

@Suite struct LogTrimTests {
    private func lines(_ n: Int, size: Int) -> [LogLine] {
        (0..<n).map { i in
            LogLine(
                id: 0, time: "", text: String(format: "%05d", i) + String(repeating: "x", count: size - 5),
                isStderr: false)
        }
    }

    @Test func dropCountHonoursBothLimits() {
        let l = lines(10, size: 100)
        #expect(LogTrim.dropCount(l, bytes: 1000, maxLines: 20, maxBytes: 2000) == (0, 0))
        #expect(LogTrim.dropCount(l, bytes: 1000, maxLines: 6, maxBytes: 2000) == (4, 400))
        #expect(LogTrim.dropCount(l, bytes: 1000, maxLines: 20, maxBytes: 350) == (7, 700))
        #expect(LogTrim.dropCount(l, bytes: 1000, maxLines: 8, maxBytes: 450) == (6, 600))
        #expect(LogTrim.dropCount(l, bytes: 1000, maxLines: 20, maxBytes: 0) == (10, 1000))
    }
}
