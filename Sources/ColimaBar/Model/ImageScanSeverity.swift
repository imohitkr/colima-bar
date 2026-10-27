import Foundation

/// The severity of one finding. Trivy and Grype use different words, so the
/// scanners map their words to these five levels.
enum ImageScanSeverity: Int, CaseIterable, Comparable, Sendable {
    case unknown, low, medium, high, critical

    /// Maps the word of a scanner. Grype says "Negligible" for the lowest
    /// level. A word that is not known becomes `unknown`.
    init(tool text: String?) {
        switch text?.lowercased() {
        case "critical": self = .critical
        case "high": self = .high
        case "medium": self = .medium
        case "low", "negligible": self = .low
        default: self = .unknown
        }
    }

    static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

    /// The word that the page and the badge show, in lower case.
    var word: String {
        switch self {
        case .critical: "critical"
        case .high: "high"
        case .medium: "medium"
        case .low: "low"
        case .unknown: "unknown"
        }
    }

    var title: String { word.capitalized }
}
