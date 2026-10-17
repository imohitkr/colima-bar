import Foundation

/// The link of the bug report form of this repo, with some fields filled in.
/// GitHub fills a field of an issue form from the query item with the id of
/// the field (see `.github/ISSUE_TEMPLATE/bug_report.yml`).
enum IssueLink {
    static let base = "https://github.com/imohitkr/colima-bar/issues/new"
    /// The longest URL. A browser or GitHub can refuse a longer one.
    static let maxBytes = 4_000
    /// A line of the `diagnostics` field is cut to this many characters.
    static let maxLine = 200
    static let moreNote = "(more in the file)"

    /// The text of the fields. `diagnostics` is a list of lines. The
    /// redactor runs over every field.
    struct Fields: Equatable, Sendable {
        var macOS: String
        var colimaBar: String
        /// The versions of Colima, Lima and docker, one line each.
        var colima: [String]
        var runtime: String
        var diagnostics: [String]
    }

    /// The fields of the form: the versions, the runtime, and the summary and
    /// the problem lines of the Doctor report (`report` must be the report of
    /// `profile`). It uses `sharedDetail`, so no registry host goes into the link.
    static func fields(
        report: DoctorReport?, versions v: ToolVersions, macOS: String, colimaBar: String, runtime: String,
        profile: String
    ) -> Fields {
        var diagnostics = ["No Doctor report."]
        if let r = report {
            diagnostics = [r.summary]
            diagnostics += r.results.filter { $0.status >= .warning }.map {
                "[\($0.status == .problem ? "problem" : "warning")] \($0.check.title): \($0.sharedDetail)"
            }
        }
        return Fields(
            macOS: macOS, colimaBar: colimaBar,
            colima: [
                "colima \(v.colima ?? "unknown")", "lima \(v.lima ?? "unknown")", "docker \(v.docker ?? "unknown")",
            ],
            runtime: "\(runtime.isEmpty ? "docker" : runtime), \(profile)", diagnostics: diagnostics)
    }

    /// The form URL. If it is too long, it drops lines from the end of
    /// `diagnostics` and adds a note. It never cuts the versions.
    static func url(_ fields: Fields, redactor: Redactor) -> URL {
        // Redact first, then cut: a cut can split a secret or a name, and
        // then the redactor does not know it any more.
        let lines = fields.diagnostics.map { String(redactor.redact($0).prefix(maxLine)) }
        let fixed = [
            ("macos", redactor.redact(fields.macOS)), ("colimabar", redactor.redact(fields.colimaBar)),
            ("colima", redactor.redact(fields.colima.joined(separator: "\n"))),
            ("runtime", redactor.redact(fields.runtime)),
        ]
        func text(keeping n: Int) -> String {
            var kept = Array(lines.prefix(n))
            if n < lines.count { kept.append(moreNote) }
            return build(fixed + [("diagnostics", kept.joined(separator: "\n"))])
        }
        for n in stride(from: lines.count, through: 0, by: -1) {
            let candidate = text(keeping: n)
            if candidate.utf8.count <= maxBytes || n == 0 { return URL(string: candidate) ?? URL(string: base)! }
        }
        return URL(string: base)!
    }

    private static func build(_ items: [(String, String)]) -> String {
        let query = items.filter { !$0.1.isEmpty }.map { "\($0.0)=\(encode($0.1))" }.joined(separator: "&")
        return "\(base)?template=bug_report.yml&\(query)"
    }

    /// Percent-encodes every byte that is not RFC 3986 unreserved
    /// (letters, digits, `-`, `.`, `_`, `~`). A space is `%20`: GitHub reads
    /// a `+` as a space, and `URLQueryItem` leaves a `+` as it is.
    static func encode(_ s: String) -> String {
        var out = ""
        for b in s.utf8 {
            switch b {
            case 0x30...0x39, 0x41...0x5A, 0x61...0x7A, 0x2D, 0x2E, 0x5F, 0x7E: out.append(Character(UnicodeScalar(b)))
            default: out += String(format: "%%%02X", b)
            }
        }
        return out
    }
}
