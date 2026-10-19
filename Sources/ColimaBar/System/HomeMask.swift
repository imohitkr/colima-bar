import Foundation

/// Shows the home folder as `~` in a text. It replaces only the whole
/// folder: `/Users/meg` stays when the home folder is `/Users/me`.
enum HomeMask {
    /// `text` with each `home` followed by `/` or by the end of a path as `~`.
    /// A path ends at a character that a folder name cannot have in the
    /// usual case: a space, a quote, a colon, a comma, a bracket or the end.
    static func apply(_ text: String, home: String) -> String {
        guard !home.isEmpty, home != "/" else { return text }
        var result = ""
        var rest = Substring(text)
        while let found = rest.range(of: home) {
            result += rest[..<found.lowerBound]
            let after = rest[found.upperBound...]
            if let next = after.first, next != "/", isNameCharacter(next) {
                result += home  // a longer name, like /Users/meg
            } else {
                result += "~"
            }
            rest = after
        }
        return result + rest
    }

    private static func isNameCharacter(_ c: Character) -> Bool {
        c.isLetter || c.isNumber || c == "." || c == "-" || c == "_"
    }
}
