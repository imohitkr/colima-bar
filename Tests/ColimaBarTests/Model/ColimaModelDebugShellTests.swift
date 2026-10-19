import Foundation
import Testing

@testable import ColimaBar

@Suite struct ColimaModelDebugShellTests {
    private let id = String(repeating: "ab12", count: 16)

    private func plan(
        state: String = "running", isDebug: Bool = false, stored: String? = nil, lastWarned: String? = nil,
        id: String? = nil
    ) -> (args: [String]?, notice: String?) {
        ColimaModel.debugShellPlan(
            state: state, isDebug: isDebug, stored: stored, lastWarned: lastWarned, id: id ?? self.id)
    }

    @Test(arguments: ["exited", "paused", "restarting", "created"])
    func aContainerThatDoesNotRunGetsNoDebugShell(state: String) {
        let p = plan(state: state)
        #expect(p.args == nil && p.notice == nil)
    }

    @Test func aDebugRunGetsNoDebugShell() {
        let p = plan(isDebug: true)
        #expect(p.args == nil && p.notice == nil)
    }

    @Test func aRunningContainerGetsTheDefaultImage() {
        let p = plan()
        #expect(p.args == [id, "busybox:latest"] && p.notice == nil)
    }

    @Test func aValidStoredImageIsUsed() {
        #expect(plan(stored: "nicolaka/netshoot").args == [id, "nicolaka/netshoot"])
    }

    @Test func aBadImageUsesBusyboxAndGivesANotice() {
        let p = plan(stored: "--privileged")
        #expect(p.args == [id, "busybox:latest"])
        #expect(p.notice?.contains("debugShellImage") == true)
    }

    @Test func aBadImageGivesTheNoticeOnlyOncePerValue() {
        let p = plan(stored: "--privileged", lastWarned: "--privileged")
        #expect(p.args == [id, "busybox:latest"] && p.notice == nil)
        #expect(plan(stored: "a b", lastWarned: "--privileged").notice != nil)
    }

    @Test func aBadIDGivesANoticeAndNoArguments() {
        let p = plan(id: "web")
        #expect(p.args == nil)
        #expect(p.notice?.contains("container ID") == true)
    }

    @Test func aCrashAlertIsSkippedForADebugContainerOnly() {
        #expect(DebugShell.isSidecar(name: DebugShell.sidecarName(id: id)))
        #expect(!DebugShell.isSidecar(name: "my-colimabar-debug-x"))
    }
}
