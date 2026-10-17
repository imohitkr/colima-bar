import Foundation

/// The result of one part: its text, or the reason that it has none, or
/// its text and the reason that some of it is missing.
struct DiagnosticsSection: Equatable, Sendable {
    enum Outcome: Equatable, Sendable {
        case ok(String)
        /// The text, and why it is not all there.
        case partial(String, String)
        case skipped(String)
        case failed(String)
    }

    let part: DiagnosticsPart
    let outcome: Outcome

    /// How the summary shows the part: `ok`, `skipped (why)` or `failed (why)`.
    var status: String {
        switch outcome {
        case .ok: "ok"
        case .partial(_, let why): "partial (\(why))"
        case .skipped(let why): "skipped (\(why))"
        case .failed(let why): "failed (\(why))"
        }
    }

    /// The lines under the heading of the part.
    var body: String {
        switch outcome {
        case .ok(let text): text.isEmpty ? "(empty)" : text
        case .partial(let text, let why): "\(text.isEmpty ? "(empty)" : text)\nPartial: \(why)."
        case .skipped(let why): "Skipped: \(why)."
        case .failed(let why): "Failed: \(why)."
        }
    }
}
