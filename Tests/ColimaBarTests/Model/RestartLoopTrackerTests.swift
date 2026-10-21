import Foundation
import Testing

@testable import ColimaBar

@Suite struct RestartLoopTrackerTests {
    private typealias V = RestartLoopTracker.Verdict
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func thirdExitInFiveMinutesStartsALoop() {
        var t = RestartLoopTracker()
        #expect(t.recordExit(id: "a", now: t0) == .first)
        #expect(t.recordExit(id: "a", now: t0 + 60) == .repeated)
        #expect(t.recordExit(id: "a", now: t0 + 120) == .loopStarted(count: 3))
        #expect(t.isLooping(id: "a", now: t0 + 120))
    }

    @Test func slowExitsDoNotLoop() {
        var t = RestartLoopTracker()
        #expect(t.recordExit(id: "a", now: t0) == .first)
        #expect(t.recordExit(id: "a", now: t0 + 180) == .repeated)
        // The first exit is 6 minutes old now, so it no longer counts.
        #expect(t.recordExit(id: "a", now: t0 + 360) == .repeated)
        #expect(!t.isLooping(id: "a", now: t0 + 360))
    }

    @Test func exitsInALoopAreSilent() {
        var t = RestartLoopTracker()
        for i in 0..<3 { _ = t.recordExit(id: "a", now: t0 + Double(i) * 30) }
        #expect(t.recordExit(id: "a", now: t0 + 90) == .stillLooping)
        #expect(t.recordExit(id: "a", now: t0 + 600) == .stillLooping)
    }

    @Test func aLoopEndsAfterTenQuietMinutes() {
        var t = RestartLoopTracker()
        for i in 0..<3 { _ = t.recordExit(id: "a", now: t0 + Double(i) * 30) }
        #expect(t.isLooping(id: "a", now: t0 + 60 + 599))
        #expect(!t.isLooping(id: "a", now: t0 + 60 + 600))
        #expect(t.recordExit(id: "a", now: t0 + 60 + 600) == .first)
    }

    @Test func theWindowEdgeIsFiveMinutes() {
        var edge = RestartLoopTracker()
        _ = edge.recordExit(id: "a", now: t0)
        _ = edge.recordExit(id: "a", now: t0 + 150)
        #expect(edge.recordExit(id: "a", now: t0 + 300) == .loopStarted(count: 3))

        var over = RestartLoopTracker()
        _ = over.recordExit(id: "a", now: t0)
        _ = over.recordExit(id: "a", now: t0 + 150)
        #expect(over.recordExit(id: "a", now: t0 + 301) == .repeated)
    }

    @Test func aShortLoopWindowEndsBeforeTheStableTime() {
        var t = RestartLoopTracker()
        for i in 0..<3 { _ = t.recordExit(id: "a", now: t0 + Double(i)) }
        #expect(t.isLooping(id: "a", now: t0 + 2 + 299, within: RestartLoopTracker.window))
        #expect(!t.isLooping(id: "a", now: t0 + 2 + 300, within: RestartLoopTracker.window))
        #expect(t.isLooping(id: "a", now: t0 + 2 + 300))
    }

    @Test func endLoopEndsOnlyALoop() {
        var t = RestartLoopTracker()
        _ = t.recordExit(id: "a", now: t0)
        t.endLoop(id: "a")
        #expect(t.recordExit(id: "a", now: t0 + 1) == .repeated)
        _ = t.recordExit(id: "a", now: t0 + 2)
        t.endLoop(id: "a")
        #expect(!t.isLooping(id: "a", now: t0 + 3))
        #expect(t.recordExit(id: "a", now: t0 + 3) == .first)
    }

    @Test func theCrashAlertMarkLastsForTheWindow() {
        var t = RestartLoopTracker()
        _ = t.recordExit(id: "a", now: t0)
        #expect(!t.crashAlerted(id: "a"))
        t.markCrashAlerted(id: "a")
        _ = t.recordExit(id: "a", now: t0 + 100)
        #expect(t.crashAlerted(id: "a"))
        // The window is empty again: a new first exit clears the mark.
        _ = t.recordExit(id: "a", now: t0 + 500)
        #expect(!t.crashAlerted(id: "a"))
    }

    @Test func containersAreIndependent() {
        var t = RestartLoopTracker()
        for i in 0..<3 { _ = t.recordExit(id: "a", now: t0 + Double(i)) }
        #expect(t.recordExit(id: "b", now: t0 + 3) == .first)
        #expect(!t.isLooping(id: "b", now: t0 + 3))
    }

    @Test func forgetResetsTheCount() {
        var t = RestartLoopTracker()
        for i in 0..<3 { _ = t.recordExit(id: "a", now: t0 + Double(i)) }
        t.forget(id: "a")
        #expect(!t.isLooping(id: "a", now: t0 + 3))
        #expect(t.recordExit(id: "a", now: t0 + 4) == .first)
    }

    @Test func pruningKeepsALiveLoop() {
        var t = RestartLoopTracker()
        for i in 0..<3 { _ = t.recordExit(id: "loop", now: t0 + 1_000 + Double(i)) }
        // Old entries, past the stable time, fill the table.
        for i in 0..<250 { _ = t.recordExit(id: "old\(i)", now: t0) }
        #expect(t.entryCount == 251)
        #expect(t.recordExit(id: "other", now: t0 + 1_100) == .first)
        #expect(t.entryCount == 2)
        #expect(t.isLooping(id: "loop", now: t0 + 1_100))
        #expect(t.recordExit(id: "loop", now: t0 + 1_100) == .stillLooping)
    }
}
