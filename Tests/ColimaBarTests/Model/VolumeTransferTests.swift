import Testing

@testable import ColimaBar

@Suite struct VolumeTransferTests {
    @Test func aBackupWithAnEstimateNamesBothSizes() {
        let t = VolumeTransfer(kind: .backup, volume: "pgdata", bytes: 120 << 20, total: Double(300 << 20))
        #expect(t.text == "Backing up pgdata… 120 MB of about 300 MB")
    }

    @Test func aBackupWithoutAnEstimateShowsTheBytes() {
        let t = VolumeTransfer(kind: .backup, volume: "pgdata", bytes: 2048)
        #expect(t.text == "Backing up pgdata… 2.0 KB" && t.fraction == nil)
    }

    @Test func aRestoreShowsAPercentage() {
        let t = VolumeTransfer(kind: .restore, volume: "pgdata", bytes: 40, total: 100)
        #expect(t.text == "Restoring pgdata… 40%")
    }

    @Test func aBackupAllRunShowsItsPlace() {
        let t = VolumeTransfer(kind: .backup, volume: "b", position: 2, count: 5)
        #expect(t.text.contains("(2 of 5)"))
    }

    @Test func aStoppingTransferSaysSo() {
        var t = VolumeTransfer(kind: .backup, volume: "b")
        t.isCancelling = true
        #expect(t.text == "Stopping…")
    }

    @Test func aCheckingRestoreHasNoFraction() {
        var t = VolumeTransfer(kind: .restore, volume: "b")
        t.isChecking = true
        #expect(t.text == "Checking b…" && t.fraction == nil)
    }
}
