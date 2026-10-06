/// Orders results of calls that can overlap: each call takes a number, and
/// a result applies only if no newer call's result applied first.
struct LatestOnly {
    private(set) var started = 0
    private(set) var applied = 0

    mutating func begin() -> Int {
        started += 1
        return started
    }

    /// True if the result of call `seq` may apply. It then becomes the last
    /// applied result.
    mutating func apply(_ seq: Int) -> Bool {
        guard seq > applied else { return false }
        applied = seq
        return true
    }

    /// True if call `seq` applied last, so its later steps may still apply.
    func isLatestApplied(_ seq: Int) -> Bool { seq == applied }
}
