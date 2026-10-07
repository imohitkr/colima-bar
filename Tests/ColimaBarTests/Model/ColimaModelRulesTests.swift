import Foundation
import Testing

@testable import ColimaBar

@Suite struct ColimaModelRulesTests {
    private func hides(
        enabled: Bool = true, revealed: Bool = false, state: VMState = .stopped,
        busy: Bool = false, dashboardOpen: Bool = false
    ) -> Bool {
        ColimaModel.hidesIcon(
            enabled: enabled, revealed: revealed, state: state,
            busy: busy, dashboardOpen: dashboardOpen)
    }

    private func ctr(_ status: String, state: String = "running") -> Container {
        Container(id: "x", name: "x", image: "i", state: state, status: status, ports: [], project: nil)
    }

    @Test func hidesWhenEnabledAndStopped() {
        #expect(hides())
    }

    @Test func staysVisibleWhenOptionIsOff() {
        #expect(!hides(enabled: false))
    }

    @Test func staysVisibleWhileRunning() {
        #expect(!hides(state: .running))
    }

    @Test func staysVisibleWhenStateIsNotKnownStopped() {
        #expect(!hides(state: .unknown))
        #expect(!hides(state: .notInstalled))
    }

    @Test func staysVisibleDuringStartStopOrRestart() {
        #expect(!hides(busy: true))
    }

    @Test func staysVisibleWhileDashboardIsOpen() {
        #expect(!hides(dashboardOpen: true))
    }

    @Test func staysVisibleAfterReopen() {
        #expect(!hides(revealed: true))
    }

    @Test func staysVisibleWhileAnotherProfileRuns() {
        #expect(
            !ColimaModel.hidesIcon(
                enabled: true, revealed: false, state: .stopped, busy: false,
                dashboardOpen: false, otherProfileRunning: true))
    }

    @Test func staleLimitIsLongWhileStoppedOrRunning() {
        #expect(ColimaModel.staleAfter(state: .stopped) == 300)
        #expect(ColimaModel.staleAfter(state: .running) == 300)
        #expect(ColimaModel.staleAfter(state: .unknown) == 60)
        #expect(ColimaModel.staleAfter(state: .notInstalled) == 60)
    }

    @Test func slowTickWheneverClosedAndNotBusy() {
        for s in [VMState.running, .stopped, .unknown, .notInstalled] {
            #expect(ColimaModel.tickInterval(state: s, busy: false, dashboardOpen: false) == .seconds(5))
            #expect(ColimaModel.tickInterval(state: s, busy: false, dashboardOpen: true) == .seconds(1))
            #expect(ColimaModel.tickInterval(state: s, busy: true, dashboardOpen: false) == .seconds(1))
        }
    }

    @Test func listsRarelyAndOnOpenOnlyWhenOld() {
        #expect(ColimaModel.staleAfter(state: .running) == 300)
        #expect(ColimaModel.staleAfter(state: .stopped) == 300)
        #expect(ColimaModel.statusMaxAgeOnOpen == 60)
    }

    @Test func dockerOrUnknownRuntimeHasSocket() {
        #expect(ColimaModel.hasDockerSocket(runtime: "docker"))
        #expect(ColimaModel.hasDockerSocket(runtime: ""))
    }

    @Test func otherRuntimesHaveNoSocket() {
        #expect(!ColimaModel.hasDockerSocket(runtime: "containerd"))
        #expect(!ColimaModel.hasDockerSocket(runtime: "incus"))
    }

    @Test func derivedListsSplitAndCount() {
        let list = [
            ctr("Up 1 minute (unhealthy)"), ctr("Exited (0) 1 hour ago", state: "exited"),
            ctr("Up 2 hours (healthy)", state: "paused"), ctr("Restarting", state: "restarting"),
            ctr("Created", state: "created"),
        ]
        let d = ColimaModel.derivedLists(list)
        #expect(d.running == list.filter(\.isRunning))
        #expect(d.stopped == list.filter { !$0.isRunning })
        #expect(d.running.count == 3 && d.stopped.count == 2)
        #expect(d.unhealthy == 1)
        let empty = ColimaModel.derivedLists([])
        #expect(empty.running.isEmpty && empty.stopped.isEmpty && empty.unhealthy == 0)
    }

    @Test func onlyDiskTabsWantDF() {
        #expect(!ColimaModel.showsDiskUsage(.containers))
        #expect(ColimaModel.showsDiskUsage(.images))
        #expect(ColimaModel.showsDiskUsage(.volumes))
        #expect(ColimaModel.showsDiskUsage(.system))
    }

    @Test func crashExitMatchesTheAlertRule() {
        for code in ["1", "2", "125", "139", "255"] { #expect(ColimaModel.isCrashExit(code), "\(code)") }
        for code in ["0", "130", "137", "143"] { #expect(!ColimaModel.isCrashExit(code), "\(code)") }
        #expect(!ColimaModel.isCrashExit(nil))
    }

    @Test func selectedProfileWithUnknownStateUsesTheListedState() {
        #expect(ColimaModel.selectedIsRunning(state: .running, listed: false))
        #expect(!ColimaModel.selectedIsRunning(state: .stopped, listed: true))
        #expect(ColimaModel.selectedIsRunning(state: .unknown, listed: true))
        #expect(!ColimaModel.selectedIsRunning(state: .unknown, listed: false))
        // Not in the list yet: it counts as running, so Delete is refused.
        #expect(ColimaModel.selectedIsRunning(state: .unknown, listed: nil))
    }

    @Test func failedContextsRetryOnlyForANewSetOrAfterTheInterval() {
        let t = Date(timeIntervalSince1970: 1000)
        let a = ["work": "unix:///a.sock"]
        let b = ["work": "unix:///a.sock", "dev": "unix:///b.sock"]
        let wait = ColimaModel.contextsRetryInterval
        #expect(!ColimaModel.contextsRetryDue(wanted: a, failed: a, failedAt: t, now: t.addingTimeInterval(60)))
        #expect(ColimaModel.contextsRetryDue(wanted: b, failed: a, failedAt: t, now: t.addingTimeInterval(60)))
        #expect(ColimaModel.contextsRetryDue(wanted: a, failed: a, failedAt: t, now: t.addingTimeInterval(wait)))
    }

    @Test func holdsFollowTheSelectedProfileDuringAWake() {
        // A wake of work runs. The stable proxy holds only while work is selected.
        let before = ColimaModel.holds(waking: ["work"], selected: "default")
        #expect(!before.stable)
        #expect(before.profiles == ["work"])
        let after = ColimaModel.holds(waking: ["work"], selected: "work")
        #expect(after.stable)
        #expect(after.profiles == ["work"])
        // The wake ends: nothing holds.
        let done = ColimaModel.holds(waking: [], selected: "work")
        #expect(!done.stable && done.profiles.isEmpty)
    }

    @Test func holdsKeepAProfileThatIsRemovedAndAddedBack() {
        // `colima list` drops work for a moment during its wake. The hold set
        // still names work, so its new proxy holds at once (ProfileProxies.sync).
        let gone = ColimaModel.holds(waking: ["work", "dev"], selected: "default")
        #expect(gone.profiles == ["work", "dev"])
        #expect(!gone.stable)
        let back = ColimaModel.holds(waking: ["work"], selected: "default")
        #expect(back.profiles == ["work"])
    }
}
