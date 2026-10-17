import Foundation

/// The text of the diagnostics file. The functions are pure. `render` runs
/// the `Redactor` once over the whole text, so no part can skip it.
enum DiagnosticsBundle {
    /// The hard size limit of the file.
    static let maxBytes = 2 * 1024 * 1024
    static let notice = "Review this file before you share it. ColimaBar can miss a secret."

    /// `ColimaBar-diagnostics-YYYYMMDD-HHMMSS.txt` in the time zone.
    static func fileName(date: Date, timeZone: TimeZone = .current) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = timeZone
        f.dateFormat = "yyyyMMdd-HHmmss"
        return "ColimaBar-diagnostics-\(f.string(from: date)).txt"
    }

    /// The end of `text`: at most `lines` lines and `bytes` bytes of UTF-8.
    /// A cut starts at a line start if it can, and never inside a character.
    /// A cut text starts with a note.
    static func tail(_ text: String, lines: Int, bytes: Int) -> String {
        var all = text.split(separator: "\n", omittingEmptySubsequences: false)
        if all.last == "" { all.removeLast() }
        var cut = false
        if all.count > lines {
            all = Array(all.suffix(max(lines, 0)))
            cut = true
        }
        var kept = all.joined(separator: "\n")
        if kept.utf8.count > bytes {
            cut = true
            let tailBytes = kept.utf8.suffix(max(bytes, 0))
            var s = String(decoding: tailBytes, as: UTF8.self)
            // The first character can be half a character: the decoder made it U+FFFD.
            while s.first == "\u{FFFD}" { s.removeFirst() }
            // Start at a line start, if the text has one.
            if let nl = s.firstIndex(of: "\n"), tailBytes.count < kept.utf8.count {
                s = String(s[s.index(after: nl)...])
            }
            kept = s
        }
        guard cut else { return kept }
        return cutNote(lines: lines, bytes: bytes) + "\n" + kept
    }

    /// The first line of a text that `tail` cut.
    static func cutNote(lines: Int, bytes: Int) -> String {
        "[older lines cut: the last \(lines) lines and \(bytes / 1024) KB at most]"
    }

    /// The start of `text`, at most `bytes` bytes of UTF-8, and a note if it cut.
    static func head(_ text: String, bytes: Int) -> String {
        guard text.utf8.count > bytes else { return text }
        var s = String(decoding: text.utf8.prefix(max(bytes, 0)), as: UTF8.self)
        while s.last == "\u{FFFD}" { s.removeLast() }
        return s + "\n[cut at \(bytes / 1024) KB]"
    }

    /// The whole file: the notice, the summary and one block for each part.
    /// `redactor` runs over all of it. The result has at most `maxBytes`.
    static func render(
        sections: [DiagnosticsSection], date: Date, version: String, isDebugRun: Bool, elapsed: TimeInterval,
        notes: [String] = [], redactor: Redactor
    ) -> String {
        var out: [String] = [notice, ""]
        out.append("ColimaBar diagnostics")
        out.append("Date: \(date.formatted(.iso8601))")
        out.append("ColimaBar: \(version)\(isDebugRun ? " (debug run)" : "")")
        out.append("Collected in \(String(format: "%.1f", elapsed)) s")
        out.append("")
        out.append("Summary")
        for s in sections { out.append("  \(s.part.title): \(s.status)") }
        for n in notes { out.append("  Note: \(n)") }
        for s in sections {
            out += ["", "== \(s.part.title) ==", s.body]
        }
        out.append("")
        return limit(redactor.redact(out.joined(separator: "\n")))
    }

    private static func limit(_ text: String) -> String {
        guard text.utf8.count > maxBytes else { return text }
        return head(text, bytes: maxBytes - 64)
    }
}
