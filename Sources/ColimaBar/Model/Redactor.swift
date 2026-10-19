import Foundation

/// Removes secrets and personal names from the text of a diagnostics file
/// and from the fields of an issue link. It is pure: the caller passes the
/// names of the Mac and the user. Running it again on its own output changes
/// nothing, because a placeholder has no dots and no secret shape.
///
/// The rules run in this order:
/// 0. The names in the path of a docker API request line.
/// 1. PEM private keys.
/// 2. Tokens of known shapes.
/// 3. The value of an `Authorization` header.
/// 4. The value of a key that names a secret.
/// 5. Host names, user info and e-mail addresses.
/// 6. The home folder, and other `/Users/NAME` folders.
/// 7. The names of the Mac and of the user.
/// 8. MAC addresses and public IP addresses.
struct Redactor: Equatable, Sendable {
    let home: String
    /// The user name and the full name.
    let userNames: [String]
    /// The computer name and the host names.
    let macNames: [String]

    init(home: String, userNames: [String] = [], macNames: [String] = []) {
        self.home = home
        self.userNames = userNames
        self.macNames = macNames
    }

    /// Hosts that stay in the text, because they say nothing about the user.
    static let publicHosts = [
        "localhost", "host.docker.internal", "host.lima.internal", "github.com", "docker.io", "docker.com",
        "ghcr.io", "ubuntu.com", "githubusercontent.com", "openssh.com", "libssh.org",
    ]
    /// Names that are too common to hide. A name of 1 or 2 letters is too short.
    static let commonNames: Set<String> = [
        "root", "admin", "user", "dev", "test", "docker", "colima", "lima", "default", "token", "redacted",
        "host", "email", "mac", "key", "private", "name", "users", "mac-name", "local", "localhost",
    ]

    func redact(_ input: String) -> String {
        var t = requestLines(input)
        t = Self.replace(
            #"-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?(?:-----END [A-Z ]*PRIVATE KEY-----|\z)"#, in: t,
            with: "<private key>")
        t = tokens(t)
        t = Self.replace(
            #"(?i)(authorization["']?\s*[:=]\s*["']?(?:Bearer|Basic|Token))[ \t]+[^\s"']+"#, in: t,
            with: "$1 <redacted>")
        t = secretValues(t)
        t = hosts(t)
        t = folders(t)
        t = names(t)
        t = addresses(t)
        return t
    }

    // MARK: - Rule 0: names in request lines

    /// `METHOD /vN.NN/containers/NAME/start` becomes
    /// `METHOD /vN.NN/containers/{name}/start`. Older builds wrote the names
    /// of containers and images in the app log.
    private func requestLines(_ text: String) -> String {
        Self.replaceMatches(#"\b(GET|POST|PUT|DELETE|HEAD|PATCH) (/[^\s"'<>?]*)"#, in: text) { m in
            "\(m[1]) \(RequestPath.hideNames(m[2]))"
        }
    }

    // MARK: - Rule 2: tokens

    private static let tokenPatterns = [
        #"\bgh[pousr]_[A-Za-z0-9_]{16,}"#,
        #"\bgithub_pat_[A-Za-z0-9_]{16,}"#,
        #"\bglpat-[A-Za-z0-9_\-]{16,}"#,
        #"\bdckr_pat_[A-Za-z0-9_\-]{16,}"#,
        #"\bxox[abprs]-[A-Za-z0-9\-]{10,}"#,
        #"\bsk-[A-Za-z0-9_\-]{20,}"#,
        #"\bnpm_[A-Za-z0-9]{20,}"#,
        #"\b(?:AKIA|ASIA)[0-9A-Z]{16}\b"#,
        #"\beyJ[A-Za-z0-9_\-]{5,}\.[A-Za-z0-9_\-]{5,}\.[A-Za-z0-9_\-]*"#,
    ]

    private func tokens(_ text: String) -> String {
        Self.tokenPatterns.reduce(text) { Self.replace($1, in: $0, with: "<token>") }
    }

    // MARK: - Rule 4: values of secret keys

    /// A key that names a secret. The stem `auth` counts only as a whole key
    /// (`auth`, `auths`) or as the end of a key (`proxy_auth`), so `author`,
    /// `authenticated` and `PreferredAuthentications` stay.
    private static let secretStem =
        #"[A-Za-z0-9_.\-]*(?:secret|token|passw(?:or)?d|passphrase|pwd|conn(?:ection)?[_-]?str(?:ing)?|api[_-]?key|access[_-]?key|credential|private[_-]?key|authorization|auth[_-]?token|[_-]auth(?![A-Za-z0-9])|(?<![A-Za-z0-9_.])auths?(?![A-Za-z0-9]))[A-Za-z0-9_.\-]*"#
    private static let valueText = #"("[^"]*"|'[^']*'|[^\s,;&}\]"']+)"#

    /// True if the whole key names a secret, by the same rule as rule 4. The
    /// Inspect page uses it, so its masking and this redaction do not drift.
    static func isSecretKey(_ key: String) -> Bool {
        key.range(of: "(?i)^\(secretStem)$", options: .regularExpression) != nil
    }

    /// True if the value looks like a secret whatever its key is: a token of
    /// a known shape, a private key, `scheme://user:password@host` (the user
    /// can be empty and the password can hold a `/`, but `host:8080/x@y` is a
    /// port and a path), or `Password=...`.
    static func hasSecretShape(_ value: String) -> Bool {
        let shapes =
            tokenPatterns + [
                #"-----BEGIN [A-Z ]*PRIVATE KEY-----"#,
                #"(?i)\b[a-z][a-z0-9+.\-]*://[^\s/@]*:(?!\d+/)[^\s@"']*@"#,
                #"(?i)\b(?:password|pwd)\s*="#,
            ]
        return shapes.contains { value.range(of: $0, options: .regularExpression) != nil }
    }

    private func secretValues(_ text: String) -> String {
        Self.hideSecretValues(in: text, with: "<redacted>")
    }

    /// Replaces the value of each secret key in `text` with `placeholder`
    /// and keeps the rest: `"key": "v"`, `key=v`, `key: v` and `--key v`.
    static func hideSecretValues(in text: String, with placeholder: String) -> String {
        var t = text
        let template = "$1" + placeholder
        // "key": "value" and "key": value
        t = replace(
            "(?i)([\"']\(secretStem)[\"']\\s*[:=]\\s*)\(valueText)", in: t, with: template,
            skip: { isKept($0) })
        // key=value and key: value
        t = replace(
            "(?i)(\\b\(secretStem)[ \\t]*[:=][ \\t]*)\(valueText)", in: t, with: template,
            skip: { isKept($0) })
        // --key value
        t = replace(
            "(?i)(--\(secretStem)[ \\t]+)(?!-)([^\\s\"']+)", in: t, with: template,
            skip: { isKept($0) })
        return t
    }

    /// A value that needs no hiding: it is already hidden, it is an
    /// authorization scheme, or it is a yes or no.
    private static func isKept(_ value: String) -> Bool {
        let v = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        return v.hasPrefix("<") || ["bearer", "basic", "token", "yes", "no", "true", "false"].contains(v.lowercased())
    }

    // MARK: - Rule 5: hosts

    private static func isPublic(_ host: String) -> Bool {
        let h = host.lowercased()
        return publicHosts.contains { h == $0 || h.hasSuffix("." + $0) }
    }

    private static func isNumeric(_ host: String) -> Bool {
        host.allSatisfy { $0.isNumber || $0 == "." || $0 == ":" || $0 == "[" || $0 == "]" }
    }

    private func hosts(_ text: String) -> String {
        var t = text
        // scheme://user:password@host, for every scheme
        t = Self.replaceMatches(
            #"(?i)\b([a-z][a-z0-9+.\-]*://)(?:([^\s/@:]*)(?::(?!\d+/)[^\s@"']*)?@)?(<[a-z\-]+>|\[[0-9a-f:]+\]|[^\s/:?#\]\[\"'),>`]+)"#,
            in: t
        ) { m in
            let host = m[3]
            let keep = host.hasPrefix("<") || Self.isPublic(host) || Self.isNumeric(host)
            return m[1] + (m[2].isEmpty ? "" : "<user>@") + (keep ? host : "<host>")
        }
        // user@host and e-mail addresses
        t = Self.replaceMatches(
            #"([A-Za-z0-9._%+\-]+)@([A-Za-z0-9\-]+(?:\.[A-Za-z0-9\-]+)*)"#, in: t
        ) { m in
            let host = m[2]
            if Self.isPublic(host) || Self.isNumeric(host) { return m[0] }
            let looksLikeMail = host.contains(".") && (host.split(separator: ".").last?.allSatisfy(\.isLetter) ?? false)
            return looksLikeMail ? "<email>" : "\(m[1])@<host>"
        }
        return t
    }

    // MARK: - Rule 6: folders

    private func folders(_ text: String) -> String {
        var t = text
        if home.count > 1 {
            t = Self.replace(
                NSRegularExpression.escapedPattern(for: home) + #"(?=[/\s"'<>)\]]|$)"#, in: t, with: "~")
            // The same path in JSON text, where a slash is written `\/`.
            let escaped = home.replacingOccurrences(of: "/", with: #"\/"#)
            t = Self.replace(
                NSRegularExpression.escapedPattern(for: escaped) + #"(?=[/\s"'<>)\]]|\\/|$)"#, in: t, with: "~")
        }
        t = Self.replace(
            #"/Users/(?!Shared(?:[/\s"']|$)|<user>)([^/\s"'<>:]+)(?=[/\s"'<>:]|$)"#, in: t,
            with: "/Users/<user>")
        return Self.replace(
            #"\\/Users\\/(?!Shared(?:[/\\\s"']|$)|<user>)([^/\\\s"'<>:]+)(?=[/\\\s"'<>:]|$)"#, in: t,
            with: #"\\/Users\\/<user>"#)
    }

    // MARK: - Rule 7: names

    private func names(_ text: String) -> String {
        var t = text
        let mac = Self.usable(macNames)
        for n in mac { t = Self.replaceWord(n, in: t, with: "<mac-name>") }
        var users: [String] = []
        for full in userNames {
            users.append(full)
            users += full.split(whereSeparator: { $0 == " " || $0 == "\u{a0}" }).map(String.init)
        }
        for n in Self.usable(users) { t = Self.replaceWord(n, in: t, with: "<user>") }
        return t
    }

    /// The names that are long enough and not common, longest first.
    private static func usable(_ names: [String]) -> [String] {
        var seen = Set<String>()
        return names.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count >= 3 && !commonNames.contains($0.lowercased()) && seen.insert($0.lowercased()).inserted }
            .sorted { $0.count > $1.count }
    }

    private static func replaceWord(_ word: String, in text: String, with placeholder: String) -> String {
        replace(
            "(?i)(?<![A-Za-z0-9])" + NSRegularExpression.escapedPattern(for: word) + "(?![A-Za-z0-9])", in: text,
            with: placeholder)
    }

    // MARK: - Rule 8: addresses

    private func addresses(_ text: String) -> String {
        var t = Self.replace(#"\b[0-9A-Fa-f]{2}(?::[0-9A-Fa-f]{2}){5}\b"#, in: text, with: "<mac>")
        t = Self.replaceMatches(#"(?<![0-9.])(?:[0-9]{1,3}\.){3}[0-9]{1,3}(?![0-9]|\.[0-9])"#, in: t) { m in
            Self.isPrivateOrSpecial(m[0]) ? m[0] : "<ip>"
        }
        return Self.replaceMatches(
            #"(?<![0-9A-Fa-f:])[23][0-9A-Fa-f]{3}(?::[0-9A-Fa-f]{0,4}){2,7}(?![0-9A-Fa-f:])"#, in: t
        ) { m in
            let groups = m[0].split(separator: ":", omittingEmptySubsequences: false)
            return m[0].contains("::") || groups.count == 8 ? "<ip>" : m[0]
        }
    }

    /// Loopback, private, link-local, shared (CGNAT), unspecified, and the
    /// numbers that are not hosts (multicast, masks, broadcast) stay.
    static func isPrivateOrSpecial(_ ip: String) -> Bool {
        let o = ip.split(separator: ".").compactMap { Int($0) }
        guard o.count == 4, o.allSatisfy({ $0 <= 255 }) else { return true }
        switch (o[0], o[1]) {
        case (0, _), (10, _), (127, _), (169, 254), (192, 168): return true
        case (172, 16...31), (100, 64...127): return true
        case (224..., _): return true
        default: return false
        }
    }

    // MARK: - Regex helpers

    /// Replaces every match with `template` (`$1` is a group). `skip` can keep
    /// a match: it gets the text of the last group.
    private static func replace(
        _ pattern: String, in text: String, with template: String, skip: ((String) -> Bool)? = nil
    ) -> String {
        guard let skip else {
            return text.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
        }
        guard let re = try? NSRegularExpression(pattern: pattern) else { return text }
        let ns = text as NSString
        var out = ""
        var last = 0
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let whole = ns.substring(with: m.range)
            let value = m.range(at: m.numberOfRanges - 1)
            if skip(ns.substring(with: value)) {
                out += whole
            } else {
                out += re.replacementString(for: m, in: text, offset: 0, template: template)
            }
            last = m.range.location + m.range.length
        }
        return out + ns.substring(from: last)
    }

    /// Replaces every match with the text that `transform` returns. It gets
    /// the whole match first, then the groups (an empty text for a group that
    /// did not match).
    private static func replaceMatches(
        _ pattern: String, in text: String, _ transform: ([String]) -> String
    ) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return text }
        let ns = text as NSString
        var out = ""
        var last = 0
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let parts = (0..<m.numberOfRanges).map { i -> String in
                let r = m.range(at: i)
                return r.location == NSNotFound ? "" : ns.substring(with: r)
            }
            out += transform(parts)
            last = m.range.location + m.range.length
        }
        return out + ns.substring(from: last)
    }
}
