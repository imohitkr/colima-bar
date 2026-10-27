import Foundation
import Testing

@testable import ColimaBar

@Suite struct ImageScanReportTests {
    private func finding(
        _ id: String, _ level: ImageScanSeverity, package: String = "pkg", fixed: String? = nil
    ) -> ImageScanFinding {
        ImageScanFinding(vulnID: id, package: package, installed: "1", fixed: fixed, severity: level, title: "")
    }

    private func report(_ findings: [ImageScanFinding]) -> ImageScanReport {
        ImageScanReport(
            tool: .trivy, toolVersion: "0.76.1", date: Date(), imageID: "abc123abc123", imageName: "nginx:latest",
            findings: findings)
    }

    @Test func sortsBySeverityThenID() {
        let r = report([finding("B", .low), finding("A", .critical), finding("C", .critical), finding("D", .high)])
        #expect(r.findings.map(\.vulnID) == ["A", "C", "D", "B"])
    }

    @Test func dropsTheSameVulnerabilityInTheSamePackage() {
        let r = report([finding("A", .high), finding("A", .high), finding("A", .high, package: "other")])
        #expect(r.findings.count == 2)
    }

    @Test func countsAndBadge() {
        let r = report([finding("A", .critical), finding("B", .critical), finding("C", .low)])
        #expect(r.count(.critical) == 2)
        #expect(r.count(.high) == 0)
        #expect(r.highest == .critical)
        #expect(r.badgeText == "2 critical")
        #expect(r.summary == "2 Critical · 1 Low")
    }

    @Test func aCleanImageHasNoBadgeSeverity() {
        let r = report([])
        #expect(r.isClean)
        #expect(r.highest == nil)
        #expect(r.badgeText == "clean")
        #expect(r.summary == "No known vulnerabilities")
    }

    @Test func rowsCapAtTheLimitAndSayHowManyAreHidden() {
        let many = (0..<(ImageScanReport.maxRows + 5)).map { finding(String(format: "CVE-%05d", $0), .medium) }
        let r = report(many)
        let rows = r.rows(onlyFixable: false)
        #expect(rows.shown.count == ImageScanReport.maxRows)
        #expect(rows.hidden == 5)
    }

    @Test func onlyFixableKeepsTheFindingsWithAFix() {
        let r = report([finding("A", .high, fixed: "2"), finding("B", .high)])
        let rows = r.rows(onlyFixable: true)
        #expect(rows.shown.map(\.vulnID) == ["A"])
        #expect(rows.hidden == 0)
    }
}
