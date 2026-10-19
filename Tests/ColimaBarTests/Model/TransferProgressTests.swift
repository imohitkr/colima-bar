import Testing

@testable import ColimaBar

@Suite struct TransferProgressTests {
    @Test func aBackupWithoutAnEstimateHasNoFraction() {
        #expect(TransferProgress.backupFraction(bytes: 500, estimate: 0) == nil)
    }

    @Test func aBackupFractionFollowsTheBytes() {
        #expect(TransferProgress.backupFraction(bytes: 50, estimate: 200) == 0.25)
    }

    @Test func aBackupNeverShowsMoreThanNinetyNinePercent() {
        #expect(TransferProgress.backupFraction(bytes: 900, estimate: 100) == 0.99)
    }

    @Test func aRestoreFractionIsTheShareSent() {
        #expect(TransferProgress.restoreFraction(sent: 40, total: 100) == 0.4)
    }

    @Test func aRestoreWithNothingToSendShowsZero() {
        #expect(TransferProgress.restoreFraction(sent: 0, total: 0) == 0)
    }

    @Test func aRestoreFractionStopsAtOne() {
        #expect(TransferProgress.restoreFraction(sent: 200, total: 100) == 1)
    }
}
