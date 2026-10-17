import Foundation

enum Parse {
    /// Top-level `key: value` from colima.yaml, or the value under a section.
    static func yaml(_ text: String, key: String, section: String? = nil) -> String? {
        var inSection = section == nil
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if let section {
                if line.hasPrefix("\(section):") {
                    inSection = true
                    continue
                }
                if inSection, let c = line.first, c.isLetter { inSection = false }
                if inSection, line.hasPrefix("  \(key):") {
                    return line.dropFirst(key.count + 3).trimmingCharacters(in: .whitespaces)
                }
            } else if line.hasPrefix("\(key):") {
                return line.dropFirst(key.count + 1).trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    /// The value of a colima.yaml line, cleaned: no inline comment (`4 # four
    /// cores`), no surrounding blanks and no matching quotes.
    static func scalar(_ raw: String) -> String {
        var v = raw
        if let hash = v.range(of: " #") { v = String(v[..<hash.lowerBound]) }
        v = v.trimmingCharacters(in: .whitespaces)
        if v.count >= 2, let q = v.first, q == "\"" || q == "'", v.last == q {
            v = String(v.dropFirst().dropLast())
        }
        return v
    }
}
