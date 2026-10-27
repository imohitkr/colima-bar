import Foundation

/// One known vulnerability in one package of an image. Both scanners give
/// these fields, so the page does not depend on the scanner.
struct ImageScanFinding: Identifiable, Equatable, Sendable {
    /// The ID of the vulnerability, for example `CVE-2024-1234`.
    let vulnID: String
    let package: String
    let installed: String
    /// The version that fixes it, or nil if there is no fix yet.
    let fixed: String?
    let severity: ImageScanSeverity
    /// A short title, or "" if the scanner gave none.
    let title: String

    /// The same vulnerability in the same package version is one finding.
    var id: String { "\(vulnID)|\(package)|\(installed)" }
    var isFixable: Bool { fixed != nil }
}
