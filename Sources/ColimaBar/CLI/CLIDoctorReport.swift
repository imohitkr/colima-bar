import Foundation

/// The output of `colimabar doctor`. The text is the text of the Doctor
/// page for a bug report. The JSON follows the rules of `CLIStatus`: every
/// key is always there, and `schemaVersion` changes only for a rename, a
/// removal or a change of a type. Neither shows a registry host or the home
/// folder (see `DoctorResult.sharedDetail`).
struct CLIDoctorReport {
    static let schemaVersion = 1

    let version: String
    let report: DoctorReport
    let home: String

    func text() -> String { report.text(home: home, version: version) }

    /// The JSON text, with sorted keys and two spaces.
    func json() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        // The encoder cannot fail for these types.
        return (try? encoder.encode(Wire(self))).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }

    private struct Wire: Encodable {
        let doctor: CLIDoctorReport
        init(_ doctor: CLIDoctorReport) { self.doctor = doctor }

        enum Keys: String, CodingKey { case schemaVersion, version, profile, problems, warnings, checks }
        enum CheckKeys: String, CodingKey { case id, title, status, detail, fix }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: Keys.self)
            try c.encode(CLIDoctorReport.schemaVersion, forKey: .schemaVersion)
            try c.encode(doctor.version, forKey: .version)
            try c.encode(doctor.report.profile, forKey: .profile)
            try c.encode(doctor.report.problems, forKey: .problems)
            try c.encode(doctor.report.warnings, forKey: .warnings)
            var checks = c.nestedUnkeyedContainer(forKey: .checks)
            for r in doctor.report.results {
                var item = checks.nestedContainer(keyedBy: CheckKeys.self)
                try item.encode(r.check.rawValue, forKey: .id)
                try item.encode(r.check.title, forKey: .title)
                try item.encode(Self.name(r.status), forKey: .status)
                try item.encode(HomeMask.apply(r.sharedDetail, home: doctor.home), forKey: .detail)
                try item.encode(r.fix?.id, forKey: .fix)
            }
        }

        private static func name(_ s: DoctorResult.Status) -> String {
            switch s {
            case .ok: "ok"
            case .warning: "warning"
            case .problem: "problem"
            case .skipped: "skipped"
            }
        }
    }
}
