import Foundation

/// The rules for names in container domains. Pure: no I/O.
enum DomainName {
    static let maxLabel = 63
    static let maxName = 253
    static let localhost = "localhost"
    /// Reserved for the HTTPS self-test. Never a route.
    static let selfTestLabel = "colimabar-selftest"

    /// One DNS label from a container, service or project name: lower case
    /// ASCII; `_`, `.` and spaces become `-`; other characters drop; runs of
    /// `-` become one; no `-` at the ends; at most 63 characters (cut, then
    /// trim `-` again). nil when nothing is left.
    static func label(_ raw: String) -> String? {
        var out = ""
        var lastDash = true  // also drops a leading `-`
        for scalar in raw.unicodeScalars {
            let ch: Character
            switch scalar {
            case "a"..."z", "0"..."9": ch = Character(scalar)
            case "A"..."Z": ch = Character(scalar).lowercased().first ?? "-"
            case "_", ".", " ", "-": ch = "-"
            default: continue
            }
            if ch == "-" {
                if lastDash { continue }
                lastDash = true
            } else {
                lastDash = false
            }
            out.append(ch)
        }
        if out.count > maxLabel { out = String(out.prefix(maxLabel)) }
        while out.hasSuffix("-") { out.removeLast() }
        return out.isEmpty ? nil : out
    }

    /// True when `label(raw)` drops a non-ASCII character of `raw`.
    static func lostCharacters(_ raw: String) -> Bool { raw.unicodeScalars.contains { !$0.isASCII } }

    /// A relative name such as `admin.shop`: 1...8 labels, each [a-z0-9-]{1,63}
    /// with no `-` at an end, at most 200 bytes.
    static func isValidRelative(_ name: String) -> Bool {
        guard !name.isEmpty, name.utf8.count <= 200 else { return false }
        let labels = name.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...8).contains(labels.count) else { return false }
        return labels.allSatisfy(isValidLabel)
    }

    private static func isValidLabel(_ s: Substring) -> Bool {
        guard (1...maxLabel).contains(s.utf8.count), s.first != "-", s.last != "-" else { return false }
        return s.utf8.allSatisfy { ($0 >= 0x61 && $0 <= 0x7A) || ($0 >= 0x30 && $0 <= 0x39) || $0 == 0x2D }
    }

    /// The host of a Host header, an absolute URL authority or an SNI value:
    /// lower case, no port, no trailing dot. nil for an IP literal (v4 or
    /// [v6]), an empty name, a name over 253 bytes, or a character outside
    /// [a-z0-9.-].
    static func normalizedHost(_ raw: String) -> String? {
        var host = raw.trimmingCharacters(in: .whitespaces).lowercased()
        if host.hasPrefix("[") { return nil }
        if let colon = host.lastIndex(of: ":") { host = String(host[..<colon]) }
        if host.hasSuffix(".") { host.removeLast() }
        guard !host.isEmpty, host.utf8.count <= maxName else { return nil }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.allSatisfy({ !$0.isEmpty && $0.utf8.count <= maxLabel }) else { return nil }
        guard
            host.utf8.allSatisfy({
                ($0 >= 0x61 && $0 <= 0x7A) || ($0 >= 0x30 && $0 <= 0x39) || $0 == 0x2D || $0 == 0x2E
            })
        else { return nil }
        // A dotted number such as 127.0.0.1 is an IP literal, not a name.
        if labels.allSatisfy({ $0.utf8.allSatisfy { $0 >= 0x30 && $0 <= 0x39 } }) { return nil }
        return host
    }

    /// `web.shop` for `web.shop.localhost`, "" for `localhost` itself, nil
    /// when `host` ends in none of `suffixes`. The longest suffix wins.
    static func relative(_ host: String, suffixes: [String]) -> String? {
        for suffix in suffixes.sorted(by: { $0.count > $1.count }) {
            if host == suffix { return "" }
            if host.hasSuffix("." + suffix) { return String(host.dropLast(suffix.count + 1)) }
        }
        return nil
    }
}
