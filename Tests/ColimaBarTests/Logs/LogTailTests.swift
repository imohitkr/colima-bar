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
