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

    var id: DoctorCheck { check }

    init(_ check: DoctorCheck, _ status: Status, _ detail: String, fix: DoctorFix? = nil) {
        self.check = check
        self.status = status
        self.detail = detail
        self.fix = fix
    }
}
