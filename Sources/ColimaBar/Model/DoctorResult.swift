/// The result of one check.
struct DoctorResult: Equatable, Sendable, Identifiable {
    /// The order is the severity: the report shows the highest one first.
    enum Status: Int, Comparable, Sendable {
        case skipped, ok, warning, problem

        static func < (a: Status, b: Status) -> Bool { a.rawValue < b.rawValue }
    }

    let check: DoctorCheck
    let status: Status
    /// One or two short sentences for the row.
    let detail: String
    var fix: DoctorFix?
    /// The text for a file or a link that leaves the Mac, if `detail` holds a
    /// private name (a registry host). Nil means `detail` is safe to share.
    var shareDetail: String?

    /// The detail for a diagnostics file and an issue link.
    var sharedDetail: String { shareDetail ?? detail }

    var id: DoctorCheck { check }

    init(
        _ check: DoctorCheck, _ status: Status, _ detail: String, fix: DoctorFix? = nil, shareDetail: String? = nil
    ) {
        self.shareDetail = shareDetail
        self.check = check
        self.status = status
        self.detail = detail
        self.fix = fix
    }
}
