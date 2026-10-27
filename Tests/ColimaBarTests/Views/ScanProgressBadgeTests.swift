import Testing

@testable import ColimaBar

@Suite struct ScanProgressBadgeTests {
    private func state(_ phase: ImageScanState.Phase) -> ImageScanState {
        ImageScanState(profile: "default", imageID: "ab", imageName: "nginx", tool: .trivy, phase: phase)
    }

    @Test func aRunningScanShowsScanning() {
        #expect(ScanProgressBadge.text(for: state(.exporting(bytes: 1, total: 2))) == "scanning…")
        #expect(ScanProgressBadge.text(for: state(.scanning(firstRun: true))) == "scanning…")
    }

    @Test func aFailedScanShowsTheFailureButACancelShowsNothing() {
        #expect(ScanProgressBadge.text(for: state(.failed(.offline))) == "scan failed")
        #expect(ScanProgressBadge.text(for: state(.failed(.cancelled))) == nil)
    }

    @Test func aFinishedScanLeavesTheRowToTheReportBadge() {
        let report = ImageScanReport(
            tool: .trivy, toolVersion: nil, date: .now, imageID: "ab", imageName: "nginx", findings: [])
        #expect(ScanProgressBadge.text(for: state(.done(report))) == nil)
    }
}
