import Foundation

/// The file of `COLIMABAR_SCAN_FIXTURE`. A debug run shows its reports
/// instead of scanning. For screenshots.
///
///     {"tool": "trivy", "available": ["trivy", "grype"],
///      "reports": {"nginx:latest": {"findings": [
///        {"id": "CVE-2024-0001", "package": "libssl3", "installed": "3.0.1", "fixed": "3.0.2",
///         "severity": "high", "title": "Buffer overflow"}]}}}
struct ImageScanFixture: Decodable {
    struct Finding: Decodable {
        let id: String
        let package: String
        let installed: String?
        let fixed: String?
        let severity: String?
        let title: String?
    }
    struct Report: Decodable {
        let findings: [Finding]
        let version: String?
    }

    let tool: String?
    let available: [String]?
    /// The reports, by image reference such as `nginx:latest`.
    let reports: [String: Report]

    var scanner: ImageScanner { tool.flatMap { ImageScanner(rawValue: $0) } ?? .trivy }

    var scanners: [ImageScanner] { (available ?? [scanner.rawValue]).compactMap { ImageScanner(rawValue: $0) } }

    func findings(of report: Report) -> [ImageScanFinding] {
        report.findings.map {
            ImageScanFinding(
                vulnID: $0.id, package: $0.package, installed: $0.installed ?? "",
                fixed: $0.fixed.flatMap { $0.isEmpty ? nil : $0 }, severity: ImageScanSeverity(tool: $0.severity),
                title: $0.title ?? "")
        }
    }
}
