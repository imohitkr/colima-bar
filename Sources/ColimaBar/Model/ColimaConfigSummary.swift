import Foundation

/// A short view of a colima.yaml for the diagnostics file. It shows the
/// values of a fixed list of simple keys. A value of any other key can hold
/// a secret or a name (`env`, `provision`, `docker`, `mounts`, `hostname`,
/// `diskImage`, `network.dns`, `k3sArgs`), so it shows only "set (not
/// included)" or "empty".
enum ColimaConfigSummary {
    /// The keys whose values the summary shows. A key of a section is
    /// `section.key`.
    static let shown: Set<String> = [
        "cpu", "disk", "memory", "arch", "runtime", "vmType", "cpuType", "mountType", "mountInotify", "rosetta",
        "binfmt", "nestedVirtualization", "portForwarder", "autoActivate", "forwardAgent", "sshConfig", "sshPort",
        "modelRunner", "kubernetes.enabled", "kubernetes.version", "network.address", "network.mode",
    ]
    /// The sections whose keys the summary lists one by one.
    private static let sections: Set<String> = ["kubernetes", "network"]
    /// A value longer than this is cut.
    private static let maxValue = 60

    private struct Entry {
        let path: String
        let inline: String
        /// Indented lines or list items follow the key.
        var hasChildren = false
        /// The key is a section that lists its own keys (`kubernetes`, `network`).
        var listsKeys = false
    }

    /// The lines of the summary, in the order of the file.
    static func lines(of text: String) -> [String] {
        parse(text).compactMap { e in
            if e.listsKeys { return nil }
            if shown.contains(e.path), !e.hasChildren {
                return "\(e.path): \(e.inline.isEmpty ? "empty" : String(e.inline.prefix(maxValue)))"
            }
            let empty = !e.hasChildren && ["", "{}", "[]", "null", "~"].contains(e.inline)
            return "\(e.path): \(empty ? "empty" : "set (not included)")"
        }
    }

    /// The top-level keys, and the keys of `kubernetes` and `network`.
    private static func parse(_ text: String) -> [Entry] {
        var entries: [Entry] = []
        var top: Int?  // the last top-level entry
        var child: Int?  // the last key of a section
        var childIndent: Int?
        for raw in text.replacingOccurrences(of: "\r", with: "").split(separator: "\n") {
            let line = String(raw)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            let indent = line.prefix { $0 == " " }.count
            let isItem = trimmed.hasPrefix("-")
            let pair = isItem ? nil : keyValue(trimmed)
            if indent == 0, let (key, value) = pair {
                entries.append(Entry(path: key, inline: value))
                top = entries.count - 1
                child = nil
                childIndent = nil
            } else if let t = top {
                entries[t].hasChildren = true
                guard sections.contains(entries[t].path), let (key, value) = pair else {
                    if let c = child { entries[c].hasChildren = true }
                    continue
                }
                if childIndent == nil { childIndent = indent }
                if indent == childIndent {
                    entries.append(Entry(path: "\(entries[t].path).\(key)", inline: value))
                    entries[t].listsKeys = true
                    child = entries.count - 1
                } else if let c = child {
                    entries[c].hasChildren = true
                }
            }
        }
        // A section with an inline value (`network: {}`) has no keys to list.
        return entries.map { e in
            var e = e
            if e.listsKeys, !e.inline.isEmpty { e.listsKeys = false }
            return e
        }
    }

    /// `key: value` with a clean value, or nil if the text is not a key line.
    private static func keyValue(_ line: String) -> (String, String)? {
        guard let colon = line.firstIndex(of: ":") else { return nil }
        let key = String(line[..<colon])
        guard !key.isEmpty, key.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }) else {
            return nil
        }
        let rest = String(line[line.index(after: colon)...])
        guard rest.isEmpty || rest.first == " " else { return nil }
        return (key, Parse.scalar(rest))
    }
}
