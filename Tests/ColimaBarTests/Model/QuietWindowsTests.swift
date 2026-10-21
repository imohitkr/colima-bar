import Foundation
import Testing

@testable import ColimaBar

@Suite struct QuietWindowsTests {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func stopSignalsMarkTheStopAsExpected() {
        for signal in ["1", "2", "3", "9", "15"] {
            var q = QuietWindows()
            q.noteKill(id: "a", signal: signal, now: t0)
            #expect(q.stopIsExpected(id: "a", now: t0 + 1), "signal \(signal)")
            #expect(!q.stopIsExpected(id: "b", now: t0 + 1))
        }
    }

    @Test func otherSignalsGiveAShortWindow() {
        for signal in ["0", "10", "28", "37", "", "TERM"] as [String?] + [nil] {
            var q = QuietWindows()
            q.noteKill(id: "a", signal: signal, now: t0)
            #expect(q.stopIsExpected(id: "a", now: t0 + 14), "signal \(signal ?? "nil")")
            #expect(!q.stopIsExpected(id: "a", now: t0 + 15), "signal \(signal ?? "nil")")
        }
    }

    @Test func aShortWindowNeverCutsALongOne() {
        var q = QuietWindows()
        q.noteKill(id: "a", signal: "15", now: t0)
        q.noteKill(id: "a", signal: "10", now: t0 + 10)
        #expect(q.stopIsExpected(id: "a", now: t0 + 100))
    }

    @Test func theStopWindowEndsAfter120Seconds() {
        var q = QuietWindows()
        q.noteKill(id: "a", signal: "15", now: t0)
        #expect(q.stopIsExpected(id: "a", now: t0 + 119))
        #expect(!q.stopIsExpected(id: "a", now: t0 + 120))
    }

    @Test func aSecondKillExtendsTheWindow() {
        var q = QuietWindows()
        q.noteKill(id: "a", signal: "15", now: t0)
        q.noteKill(id: "a", signal: "9", now: t0 + 100)
        #expect(q.stopIsExpected(id: "a", now: t0 + 200))
        #expect(!q.stopIsExpected(id: "a", now: t0 + 220))
    }

    @Test func aStartEndsTheStopWindow() {
        var q = QuietWindows()
        q.noteKill(id: "a", signal: "15", now: t0)
        q.noteStart(id: "a", now: t0 + 5)
        #expect(!q.stopIsExpected(id: "a", now: t0 + 6))
    }

    @Test func theHoldCountsDepthAndKeepsATail() {
        var q = QuietWindows()
        q.holdAll()
        q.holdAll()
        #expect(q.stopIsExpected(id: "any", now: t0))
        q.releaseAll(now: t0 + 10)
        #expect(q.isHeld(now: t0 + 1_000))
        q.releaseAll(now: t0 + 20)
        #expect(q.isHeld(now: t0 + 49))
        #expect(q.stopIsExpected(id: "any", now: t0 + 49))
        #expect(!q.isHeld(now: t0 + 50))
    }

    @Test func releaseWithoutHoldDoesNotGoNegative() {
        var q = QuietWindows()
        q.releaseAll(now: t0)
        #expect(!q.isHeld(now: t0 + 1))
        q.holdAll()
        #expect(q.isHeld(now: t0 + 1_000))
    }

    @Test func holdLeftGivesTheTimeToTheEnd() {
        var q = QuietWindows()
        #expect(q.holdLeft(now: t0) == 0)
        q.holdAll()
        #expect(q.holdLeft(now: t0) == QuietWindows.holdTail)
        q.releaseAll(now: t0 + 10)
        #expect(q.holdLeft(now: t0 + 20) == 20)
        #expect(q.holdLeft(now: t0 + 100) == 0)
    }

    @Test func pruningDropsExpiredKillWindows() {
        var q = QuietWindows()
        for i in 0..<250 { q.noteKill(id: "old\(i)", signal: "15", now: t0) }
        #expect(q.entryCount == 250)
        q.noteKill(id: "new", signal: "15", now: t0 + 500)
        #expect(q.entryCount == 1)
        #expect(q.stopIsExpected(id: "new", now: t0 + 501))
    }

    @Test func pruningDropsEndedGraces() {
        var q = QuietWindows()
        for i in 0..<250 { q.noteStart(id: "old\(i)", now: t0) }
        #expect(q.entryCount == 250)
        q.noteStart(id: "new", now: t0 + 500)
        #expect(q.entryCount == 1)
        #expect(q.startGraceLeft(id: "new", now: t0 + 500) == 180)
    }

    @Test func startGraceCountsDownToZero() {
        var q = QuietWindows()
        #expect(q.startGraceLeft(id: "a", now: t0) == 0)
        q.noteStart(id: "a", now: t0)
        #expect(q.startGraceLeft(id: "a", now: t0) == 180)
        #expect(q.startGraceLeft(id: "a", now: t0 + 100) == 80)
        #expect(q.startGraceLeft(id: "a", now: t0 + 180) == 0)
        #expect(q.startGraceLeft(id: "a", now: t0 + 500) == 0)
    }

    @Test func forgetClearsBothWindows() {
        var q = QuietWindows()
        q.noteKill(id: "a", signal: "15", now: t0)
        q.noteStart(id: "a", now: t0)
        q.noteKill(id: "a", signal: "15", now: t0)
        q.forget(id: "a")
        #expect(!q.stopIsExpected(id: "a", now: t0 + 1))
        #expect(q.startGraceLeft(id: "a", now: t0 + 1) == 0)
    }
}
