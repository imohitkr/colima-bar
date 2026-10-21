import Foundation
import Testing

@testable import ColimaBar

@Suite struct ContainerAlertGateTests {
    private typealias R = ContainerAlertGate.Result
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func event(
        _ action: String, id: String = "a", code: String? = nil, signal: String? = nil, at seconds: TimeInterval = 0
    ) -> ContainerAlertInput {
        ContainerAlertInput(
            id: id, action: action, exitCode: code, signal: signal, now: t0.addingTimeInterval(seconds))
    }

    @Test func firstCrashPosts() {
        var g = ContainerAlertGate()
        #expect(g.react(event("die", code: "1")) == .post(.crash(code: "1")))
    }

    @Test func normalExitCodesPostNothing() {
        var g = ContainerAlertGate()
        for code in ["0", "130", "137", "143"] { #expect(g.react(event("die", id: code, code: code)) == .none) }
    }

    @Test func dieAfterAStopSignalIsNoCrash() {
        var g = ContainerAlertGate()
        #expect(g.react(event("kill", signal: "15")) == .none)
        #expect(g.react(event("die", code: "1", at: 5)) == .none)
        // The exit was not counted: the next three exits give a crash, nothing and then the loop.
        #expect(g.react(event("die", code: "1", at: 130)) == .post(.crash(code: "1")))
        #expect(g.react(event("die", code: "1", at: 140)) == .none)
        #expect(g.react(event("die", code: "1", at: 150)) == .post(.loop(count: 3, lastCode: "1")))
    }

    @Test func aStartClearsTheStopWindow() {
        var g = ContainerAlertGate()
        _ = g.react(event("kill", signal: "15"))
        _ = g.react(event("start", at: 1))
        #expect(g.react(event("die", code: "1", at: 2)) == .post(.crash(code: "1")))
    }

    @Test func theStopWindowEndsAfter120Seconds() {
        var g = ContainerAlertGate()
        _ = g.react(event("kill", signal: "15"))
        #expect(g.react(event("die", code: "1", at: 121)) == .post(.crash(code: "1")))
    }

    @Test func anyOtherSignalGivesAShortWindow() {
        var within = ContainerAlertGate()
        _ = within.react(event("kill", signal: "28"))
        #expect(within.react(event("die", code: "1", at: 14)) == .none)

        var after = ContainerAlertGate()
        _ = after.react(event("kill", signal: "28"))
        #expect(after.react(event("die", code: "1", at: 16)) == .post(.crash(code: "1")))
    }

    @Test func aNormalExitBeforeACrashDoesNotHideIt() {
        var g = ContainerAlertGate()
        #expect(g.react(event("die", code: "137")) == .none)
        #expect(g.react(event("die", code: "1", at: 5)) == .post(.crash(code: "1")))
        // One crash alert for each window: the third exit is the loop.
        #expect(g.react(event("die", code: "2", at: 10)) == .post(.loop(count: 3, lastCode: "2")))
    }

    @Test func aCrashInANewWindowAlertsAgain() {
        var g = ContainerAlertGate()
        #expect(g.react(event("die", code: "1")) == .post(.crash(code: "1")))
        #expect(g.react(event("die", code: "1", at: 400)) == .post(.crash(code: "1")))
    }

    @Test func aSecondCrashInTheWindowIsSilent() {
        var g = ContainerAlertGate()
        #expect(g.react(event("die", code: "1")) == .post(.crash(code: "1")))
        #expect(g.react(event("die", code: "1", at: 10)) == .none)
    }

    @Test func aLoopEndsAfterTenStableMinutes() {
        var g = ContainerAlertGate()
        for i in 0..<3 { _ = g.react(event("die", code: "1", at: Double(i))) }
        #expect(g.react(event("die", code: "1", at: 601)) == .none)
        #expect(g.react(event("die", code: "1", at: 602 + 600)) == .post(.crash(code: "1")))
    }

    @Test func aHealthyEventEndsTheLoop() {
        var g = ContainerAlertGate()
        for i in 0..<3 { _ = g.react(event("die", code: "1", at: Double(i))) }
        #expect(g.react(event("health_status: healthy", at: 10)) == .none)
        #expect(g.react(event("die", code: "1", at: 20)) == .post(.crash(code: "1")))
    }

    @Test func aHealthyEventWithoutALoopKeepsTheCount() {
        var g = ContainerAlertGate()
        _ = g.react(event("die", code: "1"))
        _ = g.react(event("die", code: "1", at: 10))
        _ = g.react(event("health_status: healthy", at: 15))
        #expect(g.react(event("die", code: "1", at: 20)) == .post(.loop(count: 3, lastCode: "1")))
    }

    @Test func oomAndUnhealthyAreSilentOnlyInTheLoopWindow() {
        var g = ContainerAlertGate()
        for i in 0..<3 { _ = g.react(event("die", code: "1", at: Double(i))) }
        #expect(g.react(event("oom", at: 2 + 299)) == .none)
        #expect(g.react(event("health_status: unhealthy", at: 2 + 299)) == .none)
        #expect(g.react(event("oom", at: 2 + 301)) == .post(.oom))
        #expect(g.react(event("health_status: unhealthy", at: 2 + 301)) == .post(.unhealthy))
        // The crash silence still lasts until 10 minutes pass.
        #expect(g.react(event("die", code: "1", at: 2 + 302)) == .none)
    }

    @Test func aDieWithCode137AfterOomCounts() {
        var g = ContainerAlertGate()
        #expect(g.react(event("oom")) == .post(.oom))
        #expect(g.react(event("die", code: "137", at: 1)) == .none)
        #expect(g.react(event("die", code: "137", at: 2)) == .none)
        #expect(g.react(event("die", code: "137", at: 3)) == .post(.loop(count: 3, lastCode: "137")))
    }

    @Test func threeExitsGiveCrashThenNothingThenLoop() {
        var g = ContainerAlertGate()
        #expect(g.react(event("die", code: "1")) == .post(.crash(code: "1")))
        #expect(g.react(event("die", code: "1", at: 30)) == .none)
        #expect(g.react(event("die", code: "2", at: 60)) == .post(.loop(count: 3, lastCode: "2")))
        #expect(g.react(event("die", code: "1", at: 90)) == .none)
    }

    @Test func aLoopWithExitCodeZeroStillGivesTheNotice() {
        var g = ContainerAlertGate()
        #expect(g.react(event("die", code: "0")) == .none)
        #expect(g.react(event("die", code: "0", at: 30)) == .none)
        #expect(g.react(event("die", code: "0", at: 60)) == .post(.loop(count: 3, lastCode: "0")))
    }

    @Test func oomPostsUnlessTheContainerLoops() {
        var g = ContainerAlertGate()
        #expect(g.react(event("oom")) == .post(.oom))
        for i in 0..<3 { _ = g.react(event("die", code: "137", at: Double(i))) }
        #expect(g.react(event("oom", at: 10)) == .none)
    }

    @Test func oomRightBeforeTheLoopIsSilent() {
        var g = ContainerAlertGate()
        #expect(g.react(event("die", code: "1", at: 0)) == .post(.crash(code: "1")))
        // One exit so far: the die of this oom is only the second.
        #expect(g.react(event("oom", at: 1)) == .post(.oom))
        #expect(g.react(event("die", code: "1", at: 2)) == .none)
        // Two exits in the window: the die of this oom starts the loop.
        #expect(g.react(event("oom", at: 3)) == .none)
        #expect(g.react(event("die", code: "1", at: 4)) == .post(.loop(count: 3, lastCode: "1")))
    }

    @Test func deferredUnhealthyNeedsARunningVMAndAWaitingCheck() {
        func post(_ vm: Bool, _ waiting: Bool, _ fresh: Bool, _ unhealthy: Bool) -> Bool {
            ContainerAlertGate.shouldPostDeferredUnhealthy(
                vmRunning: vm, stillWaiting: waiting, listFresh: fresh, stillUnhealthy: unhealthy)
        }
        #expect(post(true, true, true, true))
        #expect(!post(true, true, true, false))
        // The list is out of reach: the alert goes out unchecked.
        #expect(post(true, true, false, false))
        // A stopped VM or a destroyed container gets none, even unchecked.
        #expect(!post(false, true, false, false))
        #expect(!post(true, false, false, false))
    }

    @Test func unhealthyInTheStartGraceWaitsForItsEnd() {
        var g = ContainerAlertGate()
        _ = g.react(event("start"))
        #expect(g.react(event("health_status: unhealthy", at: 90)) == .recheckUnhealthy(after: 91))
        #expect(g.react(event("health_status: unhealthy", at: 181)) == .post(.unhealthy))
    }

    @Test func unhealthyWithoutAStartPostsAtOnce() {
        var g = ContainerAlertGate()
        #expect(g.react(event("health_status: unhealthy")) == .post(.unhealthy))
    }

    @Test func unhealthyWhileLoopingIsSilent() {
        var g = ContainerAlertGate()
        for i in 0..<3 { _ = g.react(event("die", code: "1", at: Double(i))) }
        #expect(g.react(event("health_status: unhealthy", at: 10)) == .none)
    }

    @Test func unhealthyInTheGraceKeepsGivingARecheck() {
        var g = ContainerAlertGate()
        _ = g.react(event("start"))
        #expect(g.react(event("health_status: unhealthy", at: 10)) == .recheckUnhealthy(after: 171))
        #expect(g.react(event("health_status: unhealthy", at: 100)) == .recheckUnhealthy(after: 81))
    }

    @Test func healthyInTheGraceDoesNotMarkAnAlert() {
        var g = ContainerAlertGate()
        g.recoveryEnabled = true
        _ = g.react(event("start"))
        _ = g.react(event("health_status: unhealthy", at: 10))
        #expect(g.react(event("health_status: healthy", at: 20)) == .none)
    }

    @Test func unhealthyDuringAVMActionWaitsForTheHold() {
        var g = ContainerAlertGate()
        g.holdAll()
        #expect(g.react(event("health_status: unhealthy")) == .recheckUnhealthy(after: 31))
        #expect(g.react(event("die", code: "1")) == .none)
        g.releaseAll(now: t0 + 10)
        #expect(g.react(event("health_status: unhealthy", at: 20)) == .recheckUnhealthy(after: 21))
        #expect(g.react(event("health_status: unhealthy", at: 41)) == .post(.unhealthy))
        // The held exit was not counted: a crash, then silence.
        #expect(g.react(event("die", code: "1", at: 42)) == .post(.crash(code: "1")))
        #expect(g.react(event("die", code: "1", at: 43)) == .none)
    }

    @Test func releaseWithoutAHoldAddsNoTail() {
        var g = ContainerAlertGate()
        g.releaseAll(now: t0)
        #expect(g.react(event("die", code: "1", at: 1)) == .post(.crash(code: "1")))
    }

    @Test func onlyASentUnhealthyBannerMarksAnAlert() {
        typealias G = ContainerAlertGate
        #expect(G.marksUnhealthyAlerted(outcome: .unhealthy, sent: true))
        #expect(!G.marksUnhealthyAlerted(outcome: .unhealthy, sent: false))
        #expect(!G.marksUnhealthyAlerted(outcome: .oom, sent: true))
        #expect(!G.marksUnhealthyAlerted(outcome: .crash(code: "1"), sent: true))
    }

    @Test func recoveryNeedsAnAlertAndTheSetting() {
        var g = ContainerAlertGate()
        g.recoveryEnabled = true
        #expect(g.react(event("health_status: healthy")) == .none)
        g.markUnhealthyAlerted("a")
        #expect(g.react(event("health_status: healthy", at: 5)) == .post(.recovered))
        #expect(g.react(event("health_status: healthy", at: 10)) == .none)

        var off = ContainerAlertGate()
        off.markUnhealthyAlerted("a")
        #expect(off.react(event("health_status: healthy")) == .none)
        // The healthy event used up the mark, so a later enable gives nothing.
        off.recoveryEnabled = true
        #expect(off.react(event("health_status: healthy", at: 5)) == .none)
    }

    @Test func destroyClearsAllState() {
        var g = ContainerAlertGate()
        g.recoveryEnabled = true
        for i in 0..<3 { _ = g.react(event("die", code: "1", at: Double(i))) }
        _ = g.react(event("start", at: 3))
        _ = g.react(event("kill", signal: "15", at: 4))
        g.markUnhealthyAlerted("a")
        #expect(g.react(event("destroy", at: 5)) == .none)
        #expect(g.react(event("die", code: "1", at: 6)) == .post(.crash(code: "1")))
        #expect(g.react(event("health_status: unhealthy", at: 7)) == .post(.unhealthy))
        #expect(g.react(event("health_status: healthy", at: 8)) == .none)
    }
}
