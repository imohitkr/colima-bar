import Testing

@testable import ColimaBar

@Suite struct IconVisibilityTests {
    private func hides(
        enabled: Bool = true, revealed: Bool = false, state: VMState = .stopped,
        busy: Bool = false, dashboardOpen: Bool = false
    ) -> Bool {
        ColimaModel.hidesIcon(
            enabled: enabled, revealed: revealed, state: state,
            busy: busy, dashboardOpen: dashboardOpen)
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
}
