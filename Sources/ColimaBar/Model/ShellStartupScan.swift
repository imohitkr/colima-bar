import Foundation

/// Finds `DOCKER_HOST` in the startup files of the login shell. It reads
/// the text of the files only and runs no user code. A new terminal can
/// still differ, for example when a file loads another file.
enum ShellStartupScan {
    enum Flavor: Equatable, Sendable { case zsh, bash, fish, other }

    /// The last assignment that the scan found.
    struct Found: Equatable, Sendable {
        let file: String
        let line: Int
        /// The value, or nil when the line removes the variable.
        let value: String?
    }

    static func flavor(shell path: String) -> Flavor {
        switch (path as NSString).lastPathComponent {
        case "zsh": .zsh
        case "bash": .bash
        case "fish": .fish
        default: .other
        }
    }

    /// The files to read, in the order that the shell reads them.
    static func files(flavor: Flavor, home: String, zdotdir: String?) -> [String] {
        switch flavor {
        case .zsh:
            let dir = zdotdir.flatMap { $0.isEmpty ? nil : $0 } ?? home
            return [".zshenv", ".zprofile", ".zshrc", ".zlogin"].map { "\(dir)/\($0)" }
        case .bash:
            return [".bash_profile", ".bash_login", ".profile", ".bashrc"].map { "\(home)/\($0)" }
        case .fish:
            return ["\(home)/.config/fish/config.fish"]
        case .other:
            return ["\(home)/.profile"]
        }
    }

    /// The last assignment over all files. Later files win over earlier ones.
    static func lastAssignment(files: [(path: String, text: String)], flavor: Flavor) -> Found? {
        var found: Found?
        for f in files { found = scan(text: f.text, file: f.path, flavor: flavor) ?? found }
        return found
    }

    /// The last assignment in one file.
    static func scan(text: String, file: String, flavor: Flavor) -> Found? {
        var found: Found?
        for (i, raw) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let line = raw.replacingOccurrences(of: "\t", with: " ").trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let statements = line.replacingOccurrences(of: "&&", with: ";").replacingOccurrences(of: "||", with: ";")
                .split(separator: ";")
            for s in statements {
                let st = strippingKeywords(s.trimmingCharacters(in: .whitespaces))
                let result = flavor == .fish ? fishStatement(st) : shStatement(st)
                if let result { found = Found(file: file, line: i + 1, value: result.value) }
            }
        }
        return found
    }

    /// The statement without the words that start a block: `if [ … ]; then
    /// export DOCKER_HOST=…; fi` has the statement `then export DOCKER_HOST=…`.
    private static func strippingKeywords(_ statement: String) -> String {
        var st = statement
        while true {
            let word = st.split(separator: " ", maxSplits: 1).first.map(String.init) ?? ""
            guard ["then", "do", "else", "{", "(", "!"].contains(word) else { return st }
            st = st.dropFirst(word.count).trimmingCharacters(in: .whitespaces)
        }
    }

    /// What a statement does to DOCKER_HOST: `value` is nil for a removal.
    private struct Change {
        let value: String?
    }

    private static func shStatement(_ st: String) -> Change? {
        var words = st.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard let first = words.first else { return nil }
        if first == "unset" {
            return words.dropFirst().contains("DOCKER_HOST") ? Change(value: nil) : nil
        }
        if ["export", "typeset", "declare", "readonly"].contains(first) {
            words.removeFirst()
            while let w = words.first, w.hasPrefix("-") { words.removeFirst() }
        }
        guard let assign = words.first, assign.hasPrefix("DOCKER_HOST=") else { return nil }
        // The value starts right after "=" and can hold spaces in quotes.
        guard let eq = st.range(of: "DOCKER_HOST=") else { return nil }
        return Change(value: value(of: String(st[eq.upperBound...])))
    }

    private static func fishStatement(_ st: String) -> Change? {
        let words = st.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard words.first == "set" else { return nil }
        var flags = ""
        var rest = words.dropFirst()
        while let w = rest.first, w.hasPrefix("-") {
            flags += w.hasPrefix("--") ? (w == "--export" ? "x" : w == "--erase" ? "e" : "") : String(w.dropFirst())
            rest = rest.dropFirst()
        }
        guard rest.first == "DOCKER_HOST" else { return nil }
        if flags.contains("e") { return Change(value: nil) }
        guard flags.contains("x"), rest.count >= 2 else { return nil }
        return Change(value: value(of: rest.dropFirst().joined(separator: " ")))
    }

    /// The value at the start of `text`: quoted, or up to the first space.
    private static func value(of text: String) -> String {
        guard let q = text.first, q == "\"" || q == "'" else {
            return text.split(separator: " ", maxSplits: 1).first.map(String.init) ?? ""
        }
        let body = text.dropFirst()
        if let end = body.firstIndex(of: q) { return String(body[..<end]) }
        return String(body)
    }
}
