import Foundation

/// The rules for the custom suffix of container domains. Pure: no I/O. Only
/// names that ICANN and the IETF reserve for private use are allowed, so a
/// typo such as `dev` can never take over real sites, and the name
/// constraint of the local CA never covers a real top-level domain. The
/// shape is `test`, or one or two labels before `test`, `internal` or
/// `home.arpa`.
enum DomainSuffix {
    static let defaultValue = "colima.internal"
    static let allowedEndings = ["test", "internal", "home.arpa"]
    static let maxBytes = 100
    static let maxLabels = 4

    /// Lower case, trimmed, no leading or trailing dot.
    static func normalized(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while s.hasPrefix(".") { s.removeFirst() }
        while s.hasSuffix(".") { s.removeLast() }
        return s
    }

    /// nil when the suffix can be used, else the text for the user.
    static func problem(_ raw: String) -> String? {
        let s = normalized(raw)
        if s.isEmpty { return "Type a suffix, for example colima.internal." }
        if !s.utf8.allSatisfy(isAllowedByte) { return "Use lower-case letters, digits, hyphens and dots." }
        let labels = s.split(separator: ".", omittingEmptySubsequences: false)
        if s.utf8.count > maxBytes || labels.count > maxLabels { return "Use at most 4 parts and 100 characters." }
        if !labels.allSatisfy(isValidLabel) { return "Each part must start and end with a letter or a digit." }
        if s == "localhost" || s.hasSuffix(".localhost") { return "localhost works already. Choose another suffix." }
        if s == "local" || s.hasSuffix(".local") {
            return ".local does not work: macOS sends .local names to multicast DNS."
        }
        if !hasAllowedShape(labels.map(String.init)) {
            return "Use one or two parts before .test, .internal or .home.arpa. Or use test."
        }
        return nil
    }

    /// `test`, or one or two labels before `test`, `internal` or `home.arpa`.
    private static func hasAllowedShape(_ labels: [String]) -> Bool {
        if labels == ["test"] { return true }
        for ending in allowedEndings {
            let tail = ending.split(separator: ".").map(String.init)
            guard labels.count > tail.count, Array(labels.suffix(tail.count)) == tail else { continue }
            return (1...2).contains(labels.count - tail.count)
        }
        return false
    }

    /// The normalized suffix when it passes `problem`, else nil.
    static func valid(_ raw: String) -> String? {
        let s = normalized(raw)
        return problem(s) == nil ? s : nil
    }

    private static func isAllowedByte(_ b: UInt8) -> Bool {
        (b >= 0x61 && b <= 0x7A) || (b >= 0x30 && b <= 0x39) || b == 0x2D || b == 0x2E
    }

    private static func isValidLabel(_ l: Substring) -> Bool {
        !l.isEmpty && l.utf8.count <= 63 && l.first != "-" && l.last != "-"
    }
}
