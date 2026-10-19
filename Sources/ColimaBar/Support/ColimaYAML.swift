import Foundation

/// A small editor for the keys of colima.yaml that the VM settings change.
/// ColimaBar has no YAML library, and the file has comments and keys that
/// ColimaBar does not know. So the editor works on lines. It finds the span of
/// one key (the key line and the indented lines or `- ` items below it) and
/// replaces only that span. Every other byte stays, also the comments. A file
/// with CRLF line ends keeps them.
///
/// It reads a plain value, `null`, `~`, `[]`, `{}`, a flow list on one line and
/// a block list. It refuses anchors, tags, block scalars, a flow list over
/// several lines and a map where it expects a value. Then it throws
/// `Failure.unsupported`, and the caller makes that setting read-only.
enum ColimaYAML {
    struct Failure: Error, Equatable, LocalizedError {
        /// The key, with dots for a nested key, for example `network.dns`.
        let key: String

        static func unsupported(_ key: String) -> Failure { Failure(key: key) }

        var errorDescription: String? {
            "ColimaBar cannot edit this form of \(key). Edit colima.yaml by hand."
        }
    }

    /// The value of a key.
    enum Value: Equatable {
        case null
        case scalar(String)
        case list([String])
        /// `{}`
        case emptyMap
    }

    // MARK: Reading

    /// The value of a key, or nil if the key is not in the file.
    static func value(_ path: [String], in text: String) throws -> Value? {
        let rows = Doc(text).rows
        guard case .found(let span) = try locate(path, in: rows) else { return nil }
        return try read(span, rows: rows, name: path.joined(separator: "."))
    }

    /// True only for an explicit `mounts: []`. Colima 0.10.3 then mounts the
    /// home folder (`MountsOrDefault`). A missing key and `null` mount nothing.
    static func hasEmptyMounts(in text: String) throws -> Bool {
        let rows = Doc(text).rows
        guard case .found(let span) = try locate(["mounts"], in: rows) else { return false }
        return span.rest == "[]"
    }

    /// The `mounts` list. A missing key, `null` and `[]` give an empty list.
    /// Use `hasEmptyMounts` to tell `[]` from the others.
    static func mounts(in text: String) throws -> [VMMount] {
        let rows = Doc(text).rows
        guard case .found(let span) = try locate(["mounts"], in: rows) else { return [] }
        let rest = span.rest
        if !rest.isEmpty {
            if rest == "[]" || isNull(rest) { return [] }
            throw Failure.unsupported("mounts")
        }
        return try mountItems(span, rows: rows)
    }

    // MARK: Writing

    /// Sets a key to a plain value.
    static func setScalar(_ path: [String], to value: String, in text: String) throws -> String {
        try write(path, in: text) { key, pad in ["\(pad)\(key): \(quoted(value, flow: false))"] }
    }

    /// Sets a key to a list, in the flow form: `dns: [1.1.1.1, 8.8.8.8]`.
    static func setList(_ path: [String], to items: [String], in text: String) throws -> String {
        try write(path, in: text) { key, pad in
            ["\(pad)\(key): [\(items.map { quoted($0, flow: true) }.joined(separator: ", "))]"]
        }
    }

    /// Sets `mounts` in the block form.
    static func setMounts(_ mounts: [VMMount], in text: String) throws -> String {
        try write(["mounts"], in: text) { key, pad in
            guard !mounts.isEmpty else { return ["\(pad)\(key): []"] }
            var out = ["\(pad)\(key):"]
            for m in mounts {
                out.append("\(pad)  - location: \(quoted(m.location, flow: false))")
                out.append("\(pad)    writable: \(m.writable)")
                if let point = m.mountPoint { out.append("\(pad)    mountPoint: \(quoted(point, flow: false))") }
            }
            return out
        }
    }

    // MARK: Lines

    /// The lines of the text. A line keeps its "\r", so an unchanged line
    /// keeps its bytes. The text splits at the bytes, because Swift reads
    /// "\r\n" as one character.
    private struct Doc {
        var lines: [String]
        let crlf: Bool

        init(_ text: String) {
            lines = text.utf8.split(separator: 10, omittingEmptySubsequences: false)
                .map { String(decoding: $0, as: UTF8.self) }
            crlf = text.contains("\r\n")
        }

        var text: String { lines.joined(separator: "\n") }

        var rows: [Row] { lines.map(Row.init) }
    }

    private struct Row {
        let indent: Int
        /// The line without its indent and its "\r".
        let body: String

        init(_ line: String) {
            var s = Substring(line)
            if s.hasSuffix("\r") { s = s.dropLast() }
            let spaces = s.prefix { $0 == " " }
            indent = spaces.count
            body = String(s.dropFirst(spaces.count))
        }

        var isBlank: Bool { body.isEmpty || body.hasPrefix("#") || body.allSatisfy { $0 == " " } }
        var isItem: Bool { body == "-" || body.hasPrefix("- ") }
    }

    private struct Span {
        let start: Int
        /// One after the last line of the key. Blank and comment lines at
        /// the end are not part of it.
        let end: Int
        let indent: Int
        let key: String
        /// The text after the colon, without a comment.
        let rest: String
    }

    private enum Location {
        case found(Span)
        /// `parent` is the deepest section that exists, nil for the file.
        /// `missing` is the rest of the path.
        case absent(parent: Span?, missing: [String])
    }

    private static let keyCharacters = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_.-")

    /// `key: rest` or `key:`. A comment stays in `rest`.
    private static func keyLine(_ body: String) -> (key: String, rest: String)? {
        guard let colon = body.firstIndex(of: ":") else { return nil }
        let key = body[..<colon]
        guard !key.isEmpty, key.allSatisfy(keyCharacters.contains) else { return nil }
        let after = body[body.index(after: colon)...]
        guard after.isEmpty || after.first == " " || after.first == "\t" else { return nil }
        return (String(key), after.trimmingCharacters(in: .whitespaces))
    }

    /// The name of a quoted key: `"dns":` or `'dns':`. The editor does not
    /// see such a key, so it must not add a second one.
    private static func quotedKey(_ body: String) -> String? {
        guard let q = body.first, q == "\"" || q == "'" else { return nil }
        let rest = body.dropFirst()
        guard let close = rest.firstIndex(of: q) else { return nil }
        let after = rest[rest.index(after: close)...]
        guard after.first == ":", after.dropFirst().first.map({ $0 == " " || $0 == "\t" }) ?? true else { return nil }
        return String(rest[..<close])
    }

    /// The text without a comment. A `#` starts a comment at the start or
    /// after a blank, outside quotes.
    private static func stripComment(_ text: String) -> String {
        var quote: Character?
        var previous: Character = " "
        var out = ""
        for c in text {
            if let q = quote {
                if c == q { quote = nil }
            } else if c == "\"" || c == "'" {
                quote = c
            } else if c == "#", previous == " " || previous == "\t" {
                break
            }
            out.append(c)
            previous = c
        }
        return out.trimmingCharacters(in: .whitespaces)
    }

    private static func isNull(_ s: String) -> Bool { ["null", "Null", "NULL", "~"].contains(s) }

    private static func span(at i: Int, key: String, rest: String, rows: [Row], limit: Int) -> Span {
        let indent = rows[i].indent
        let cleanRest = stripComment(rest)
        // A list can start at the indent of its key.
        let sameIndentItems = cleanRest.isEmpty
        var last = i
        var j = i + 1
        while j < limit {
            let r = rows[j]
            if r.isBlank {
                j += 1
            } else if r.indent > indent || (sameIndentItems && r.indent == indent && r.isItem) {
                last = j
                j += 1
            } else {
                break
            }
        }
        return Span(start: i, end: last + 1, indent: indent, key: key, rest: cleanRest)
    }

    /// The key `name` in a section. It throws `Failure.unsupported(full)` if
    /// the section has the key in quotes, because the editor would add a
    /// second key.
    private static func child(
        named name: String, full: String, in rows: [Row], range: Range<Int>
    ) throws -> Span? {
        guard let first = range.first(where: { !rows[$0].isBlank }) else { return nil }
        let indent = rows[first].indent
        for i in range where !rows[i].isBlank && rows[i].indent == indent {
            if quotedKey(rows[i].body) == name { throw Failure.unsupported(full) }
            guard let line = keyLine(rows[i].body), line.key == name else { continue }
            return span(at: i, key: name, rest: line.rest, rows: rows, limit: range.upperBound)
        }
        return nil
    }

    private static func locate(_ path: [String], in rows: [Row]) throws -> Location {
        var range = 0..<rows.count
        var parent: Span?
        for (n, name) in path.enumerated() {
            guard let found = try child(named: name, full: path[...n].joined(separator: "."), in: rows, range: range)
            else {
                return .absent(parent: parent, missing: Array(path[n...]))
            }
            if n == path.count - 1 { return .found(found) }
            if !found.rest.isEmpty {
                if found.rest == "{}" || isNull(found.rest) {
                    return .absent(parent: found, missing: Array(path[(n + 1)...]))
                }
                throw Failure.unsupported(path[...n].joined(separator: "."))
            }
            parent = found
            range = (found.start + 1)..<found.end
        }
        return .absent(parent: parent, missing: [])
    }

    // MARK: Values

    private static func read(_ span: Span, rows: [Row], name: String) throws -> Value {
        let rest = span.rest
        let children = (span.start + 1)..<span.end
        if rest.isEmpty {
            guard let first = children.first(where: { !rows[$0].isBlank }) else { return .null }
            guard rows[first].isItem else { throw Failure.unsupported(name) }
            return .list(try blockList(children, rows: rows, name: name))
        }
        guard let head = rest.first, !"&*!|>@`%".contains(head) else { throw Failure.unsupported(name) }
        // The key must not have lines below its value.
        guard children.allSatisfy({ rows[$0].isBlank }) else { throw Failure.unsupported(name) }
        if head == "[" {
            guard rest.hasSuffix("]") else { throw Failure.unsupported(name) }
            return .list(try flowList(String(rest.dropFirst().dropLast()), name: name))
        }
        if head == "{" {
            guard rest == "{}" else { throw Failure.unsupported(name) }
            return .emptyMap
        }
        if isNull(rest) { return .null }
        return .scalar(try unquote(rest, name: name))
    }

    private static func unquote(_ text: String, name: String) throws -> String {
        guard let q = text.first, q == "\"" || q == "'" else { return text }
        guard text.count >= 2, text.last == q else { throw Failure.unsupported(name) }
        let inner = String(text.dropFirst().dropLast())
        if q == "'" { return inner.replacingOccurrences(of: "''", with: "'") }
        guard inner.contains("\\") else { return inner }
        var out = ""
        var escaped = false
        for c in inner {
            if escaped {
                guard c == "\\" || c == "\"" else { throw Failure.unsupported(name) }
                out.append(c)
                escaped = false
            } else if c == "\\" {
                escaped = true
            } else {
                out.append(c)
            }
        }
        guard !escaped else { throw Failure.unsupported(name) }
        return out
    }

    private static func flowList(_ inner: String, name: String) throws -> [String] {
        var items: [String] = []
        var current = ""
        var quote: Character?
        for c in inner {
            if let q = quote {
                if c == q { quote = nil }
                current.append(c)
            } else if c == "\"" || c == "'" {
                quote = c
                current.append(c)
            } else if c == "," {
                items.append(current)
                current = ""
            } else if "[]{}".contains(c) {
                throw Failure.unsupported(name)
            } else {
                current.append(c)
            }
        }
        guard quote == nil else { throw Failure.unsupported(name) }
        items.append(current)
        let trimmed = items.map { $0.trimmingCharacters(in: .whitespaces) }
        // `[]` is one empty item. A comma at the end is allowed in YAML.
        let kept = trimmed.enumerated().filter { !$0.element.isEmpty || $0.offset < trimmed.count - 1 }.map(\.element)
        return try kept.map { item in
            guard !item.isEmpty, let head = item.first, !"&*!|>@`%".contains(head) else {
                throw Failure.unsupported(name)
            }
            return try unquote(item, name: name)
        }
    }

    private static func blockList(_ range: Range<Int>, rows: [Row], name: String) throws -> [String] {
        var items: [String] = []
        var indent: Int?
        for i in range where !rows[i].isBlank {
            let row = rows[i]
            guard row.isItem, row.indent == (indent ?? row.indent) else { throw Failure.unsupported(name) }
            indent = row.indent
            let text = stripComment(String(row.body.dropFirst()))
            guard let head = text.first, !"&*!|>@`%[{".contains(head) else { throw Failure.unsupported(name) }
            // `- key: value` is a map.
            if keyLine(text) != nil, !text.hasPrefix("\""), !text.hasPrefix("'") {
                throw Failure.unsupported(name)
            }
            items.append(try unquote(text, name: name))
        }
        return items
    }

    private static func mountItems(_ span: Span, rows: [Row]) throws -> [VMMount] {
        let name = "mounts"
        let range = (span.start + 1)..<span.end
        guard let first = range.first(where: { !rows[$0].isBlank }) else { return [] }
        guard rows[first].isItem else { throw Failure.unsupported(name) }
        let itemIndent = rows[first].indent
        var mounts: [VMMount] = []
        var entries: [(key: String, value: String)] = []
        var entryIndent: Int?
        var open = false

        func close() throws {
            guard open else { return }
            var location: String?
            var writable = false
            var point: String?
            for e in entries {
                switch e.key {
                case "location": location = location ?? e.value
                case "writable":
                    guard e.value == "true" || e.value == "false" else { throw Failure.unsupported(name) }
                    writable = e.value == "true"
                case "mountPoint": point = point ?? e.value
                default: throw Failure.unsupported(name)
                }
            }
            guard let location, !location.isEmpty else { throw Failure.unsupported(name) }
            mounts.append(VMMount(location: location, writable: writable, mountPoint: point))
            entries = []
            entryIndent = nil
        }

        func add(_ body: String, indent: Int) throws {
            guard let line = keyLine(body) else { throw Failure.unsupported(name) }
            if let entryIndent, entryIndent != indent { throw Failure.unsupported(name) }
            entryIndent = indent
            let text = line.rest.isEmpty ? "" : stripComment(line.rest)
            if let head = text.first, "&*!|>@`%[{".contains(head) || isNull(text) { throw Failure.unsupported(name) }
            entries.append((line.key, try unquote(text, name: name)))
        }

        for i in range where !rows[i].isBlank {
            let row = rows[i]
            if row.isItem, row.indent == itemIndent {
                try close()
                open = true
                let after = row.body.dropFirst()
                let spaces = after.prefix { $0 == " " }
                try add(String(after.dropFirst(spaces.count)), indent: row.indent + 1 + spaces.count)
            } else if open, row.indent > itemIndent {
                try add(row.body, indent: row.indent)
            } else {
                throw Failure.unsupported(name)
            }
        }
        try close()
        return mounts
    }

    // MARK: Write

    private static func write(
        _ path: [String], in text: String, make: (_ key: String, _ pad: String) -> [String]
    ) throws -> String {
        var doc = Doc(text)
        let rows = doc.rows
        let crlf = doc.crlf
        func fresh(_ line: String) -> String { crlf ? line + "\r" : line }
        switch try locate(path, in: rows) {
        case .found(let span):
            doc.lines.replaceSubrange(
                span.start..<span.end, with: make(span.key, String(repeating: " ", count: span.indent)).map(fresh))
        case .absent(let parent, let missing):
            var at: Int
            var indent: Int
            if let parent {
                if !parent.rest.isEmpty {
                    // `docker: {}` becomes `docker:` and gets children.
                    doc.lines[parent.start] = fresh(String(repeating: " ", count: parent.indent) + parent.key + ":")
                }
                at = parent.end
                indent = rows[(parent.start + 1)..<parent.end].first { !$0.isBlank }?.indent ?? parent.indent + 2
            } else {
                // The end of the file, after the last line that has text.
                at = doc.lines.count
                if doc.lines.last == "" { at -= 1 }
                indent = 0
            }
            var lines: [String] = []
            for (n, name) in missing.enumerated() {
                let pad = String(repeating: " ", count: indent)
                if n == missing.count - 1 {
                    lines += make(name, pad)
                } else {
                    lines.append("\(pad)\(name):")
                    indent += 2
                }
            }
            doc.lines.insert(contentsOf: lines.map(fresh), at: at)
        }
        return doc.text
    }

    /// The text for a value. It adds double quotes when plain text would
    /// change the meaning, for example `~`, a `: `, or a `:` inside a flow list.
    static func quoted(_ s: String, flow: Bool) -> String {
        var need = s.isEmpty || s != s.trimmingCharacters(in: .whitespaces)
        need = need || s.contains(": ") || s.contains(" #") || s.hasSuffix(":") || s.contains("\t")
        need = need || s == "~" || s == "-" || s.hasPrefix("- ")
        if let head = s.first, "!&*?[]{}|>'\"%@`#,".contains(head) { need = true }
        if flow, s.contains(where: { ",[]{}:".contains($0) }) { need = true }
        guard need else { return s }
        let escaped = s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}
