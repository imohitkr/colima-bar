import Observation

/// What the Inspect page holds. It is an `@Observable` object, not `@State`:
/// the SwiftUI macro plugin is not in the Command Line Tools. It lives in
/// `ViewState`, which clears it when the page closes. Environment values
/// stay in this object only: not in the model, the status file or the
/// diagnostics.
@MainActor @Observable
final class InspectState {
    var detail: ContainerDetail?
    var gone = false
    /// The reads that failed one after the other. A read that works resets it.
    private(set) var failedReads = 0
    private(set) var failureReason: String?
    /// The last read gave no answer, so the detail can be old.
    private(set) var isStale = false
    /// The page logged a failure already. It logs once for each open.
    private var didLogFailure = false

    static let failureLimit = 3
    /// The hidden values that the user showed. Keys are `env:KEY` and `label:KEY`.
    private(set) var revealed: Set<String> = []

    func reset() {
        detail = nil
        gone = false
        revealed = []
        failedReads = 0
        failureReason = nil
        isStale = false
        didLogFailure = false
    }

    /// A read worked.
    func recordFound(_ d: ContainerDetail) {
        if detail != d { detail = d }
        gone = false
        failedReads = 0
        failureReason = nil
        isStale = false
    }

    /// A read got no answer (VM stopped or busy). It is not a failure.
    func recordUnavailable() { isStale = true }

    /// A read failed. It returns true the first time in one page open, so
    /// the caller logs only once.
    func recordFailure(_ reason: String) -> Bool {
        failedReads += 1
        failureReason = reason
        isStale = true
        defer { didLogFailure = true }
        return !didLogFailure
    }

    /// The text for the user: after the first read failed, or after 3 reads
    /// in a row failed.
    var problem: String? {
        guard let reason = failureReason, detail == nil || failedReads >= Self.failureLimit else { return nil }
        return "ColimaBar could not read this container (\(reason))."
    }

    func isRevealed(_ key: String) -> Bool { revealed.contains(key) }

    func toggle(_ key: String) {
        if !revealed.insert(key).inserted { revealed.remove(key) }
    }
}
