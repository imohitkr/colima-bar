import Foundation

/// The result of one scan. The findings are sorted by severity, then by ID.
/// The report lives in memory only: ColimaBar saves no list of vulnerabilities.
struct ImageScanReport: Equatable, Sendable {
    /// The most rows that the page shows. It says how many more there are.
    static let maxRows = 1000

    let tool: ImageScanner
    let toolVersion: String?
    let date: Date
    /// The image ID without `sha256:`.
    let imageID: String
    /// The name that the user saw when the scan started.
    let imageName: String
    let findings: [ImageScanFinding]
    let counts: [ImageScanSeverity: Int]

    init(
        tool: ImageScanner, toolVersion: String?, date: Date, imageID: String, imageName: String,
        findings: [ImageScanFinding]
    ) {
        self.tool = tool
        self.toolVersion = toolVersion
        self.date = date
        self.imageID = imageID
        self.imageName = imageName
        var seen = Set<String>()
        let unique = findings.filter { seen.insert($0.id).inserted }
        self.findings = unique.sorted {
            if $0.severity != $1.severity { return $0.severity > $1.severity }
            if $0.vulnID != $1.vulnID { return $0.vulnID < $1.vulnID }
            return $0.package < $1.package
        }
        counts = Dictionary(grouping: unique, by: \.severity).mapValues(\.count)
    }

    func count(_ severity: ImageScanSeverity) -> Int { counts[severity] ?? 0 }

    /// The highest severity of any finding, or nil for a clean image.
    var highest: ImageScanSeverity? { findings.first?.severity }

    var isClean: Bool { findings.isEmpty }

    /// The text of the badge on the Images tab: "3 critical", or "clean".
    var badgeText: String {
        guard let top = highest else { return "clean" }
        return "\(count(top)) \(top.word)"
    }

    /// The text of the severity strip, for the levels that have findings:
    /// "2 Critical · 7 High".
    var summary: String {
        let parts = ImageScanSeverity.allCases.reversed().compactMap { level -> String? in
            let n = count(level)
            return n == 0 ? nil : "\(n) \(level.title)"
        }
        return parts.isEmpty ? "No known vulnerabilities" : parts.joined(separator: " · ")
    }

    /// The rows to show: at most `maxRows`, and `hidden` rows more.
    func rows(onlyFixable: Bool) -> (shown: [ImageScanFinding], hidden: Int) {
        let all = onlyFixable ? findings.filter(\.isFixable) : findings
        return (Array(all.prefix(Self.maxRows)), max(0, all.count - Self.maxRows))
    }
}
