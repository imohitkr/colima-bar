import Foundation

/// Decides how many of the oldest lines to drop, so that at most
/// `maxLines` lines and `maxBytes` bytes of text remain.
enum LogTrim {
    /// The UTF-8 size of a line's text. Native strings store it, so this is O(1).
    static func size(_ l: LogLine) -> Int { l.text.utf8.count }

    /// Returns the number of lines to drop from the front and their bytes.
    static func dropCount(_ lines: [LogLine], bytes: Int, maxLines: Int, maxBytes: Int) -> (count: Int, bytes: Int) {
        var drop = max(0, lines.count - maxLines)
        var freed = 0
        for i in 0..<drop { freed += size(lines[i]) }
        while bytes - freed > maxBytes, drop < lines.count {
            freed += size(lines[drop])
            drop += 1
        }
        return (drop, freed)
    }
}
