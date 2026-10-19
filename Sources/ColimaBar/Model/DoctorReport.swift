import Foundation

/// The results of one Doctor run for one profile.
struct DoctorReport: Equatable, Sendable {
    let profile: String
    let date: Date
    let results: [DoctorResult]

    /// Doctor runs again when the page opens and the report is older.
    static let staleAfter: TimeInterval = 5 * 60

    var problems: Int { results.filter { $0.status == .problem }.count }
    var warnings: Int { results.filter { $0.status == .warning }.count }

    /// For example "1 problem, 2 warnings", or "No problems".
    var summary: String {
        var parts: [String] = []
        if problems > 0 { parts.append("\(problems) \(problems == 1 ? "problem" : "problems")") }
        if warnings > 0 { parts.append("\(warnings) \(warnings == 1 ? "warning" : "warnings")") }
        return parts.isEmpty ? "No problems" : parts.joined(separator: ", ")
    }

    func isStale(now: Date) -> Bool { now.timeIntervalSince(date) > Self.staleAfter }

    /// Plain text for a bug report. It shows the home folder as `~`. It holds
    /// no secrets: the checks read only names, never registry logins. It
    /// shows no registry host (see `DoctorResult.sharedDetail`).
    func text(home: String, version: String) -> String {
        var lines = ["ColimaBar \(version), profile \(profile), \(summary)"]
        for r in results {
            let tag: String
            switch r.status {
            case .ok: tag = "ok"
            case .warning: tag = "warning"
            case .problem: tag = "problem"
            case .skipped: tag = "skipped"
            }
            lines.append("[\(tag)] \(r.check.title): \(r.sharedDetail)")
        }
        return HomeMask.apply(lines.joined(separator: "\n"), home: home)
    }
}
