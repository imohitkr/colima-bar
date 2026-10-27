import Foundation

/// The JSON that `trivy image --format json` writes. It has only the fields
/// that ColimaBar reads. `Vulnerabilities` is absent for a result with none.
struct TrivyReport: Decodable {
    struct Result: Decodable {
        let vulnerabilities: [Vulnerability]?

        enum CodingKeys: String, CodingKey { case vulnerabilities = "Vulnerabilities" }
    }

    struct Vulnerability: Decodable {
        let id: String
        let package: String
        let installed: String?
        let fixed: String?
        let severity: String?
        let title: String?

        enum CodingKeys: String, CodingKey {
            case id = "VulnerabilityID"
            case package = "PkgName"
            case installed = "InstalledVersion"
            case fixed = "FixedVersion"
            case severity = "Severity"
            case title = "Title"
        }
    }

    let results: [Result]?

    enum CodingKeys: String, CodingKey { case results = "Results" }

    var findings: [ImageScanFinding] {
        (results ?? []).flatMap { $0.vulnerabilities ?? [] }.map {
            ImageScanFinding(
                vulnID: $0.id, package: $0.package, installed: $0.installed ?? "",
                fixed: $0.fixed.flatMap { $0.isEmpty ? nil : $0 }, severity: ImageScanSeverity(tool: $0.severity),
                title: ($0.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
}
