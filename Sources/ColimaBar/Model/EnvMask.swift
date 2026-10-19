import Foundation

/// Decides which values of a container the Inspect page hides. The rules for
/// secret names and secret shapes come from `Redactor`, so the page and the
/// diagnostics file agree.
enum EnvMask {
    /// What the page shows in place of a hidden value.
    static let mask = "••••••"

    /// A key that ends in key, pass, dsn or salt as a whole word. `Redactor`
    /// does not hide a bare `STRIPE_KEY` in a diagnostics file, but the page
    /// is stricter: one click shows the value.
    private static let extraKeyRule = #"(?i)(^|[_-])(key|pass|dsn|salt)$"#

    static func isSecret(key: String, value: String) -> Bool {
        isSecretName(key) || Redactor.hasSecretShape(value)
    }

    static func isSecretName(_ key: String) -> Bool {
        Redactor.isSecretKey(key) || key.range(of: extraKeyRule, options: .regularExpression) != nil
    }

    /// The entries of `Config.Env`. An entry splits at the first `=`. An
    /// entry with no `=` has an empty value.
    static func entries(_ env: [String]) -> [EnvEntry] {
        env.map { item in
            let key: String
            let value: String
            if let eq = item.firstIndex(of: "=") {
                key = String(item[..<eq])
                value = String(item[item.index(after: eq)...])
            } else {
                key = item
                value = ""
            }
            return EnvEntry(key: key, value: value, isSecret: isSecret(key: key, value: value))
        }
    }

    /// A flag name that holds one of these words anywhere hides its value:
    /// `--requirepass`, `--masterauth`, `--passphrase`, `--api-key`.
    private static let flagWords = "pass|auth|secret|token|key"

    private static func isSecretFlagName(_ name: String) -> Bool {
        name.range(of: "(?i)(\(flagWords))", options: .regularExpression) != nil
    }

    /// `--flag value` and `--flag=value` inside one word, for a flag name with
    /// a secret word. The value is a quoted text or a run with no space.
    private static let embeddedFlag =
        "(?i)(--[A-Za-z0-9_.\\-]*(?:\(flagWords))[A-Za-z0-9_.\\-]*(?:[ \\t]+|=))(?!-)(\"[^\"]*\"|'[^']*'|[^\\s\"']+)"

    /// The words of a command with the secrets hidden: the value after a
    /// secret flag (`--password x`), the value of `--token=x` or `KEY=x`,
    /// any word that has a secret shape, and the secret values inside one
    /// word, such as the text of `sh -c "... --token=x"`.
    static func maskArgs(_ args: [String]) -> [String] {
        var out: [String] = []
        var hideNext = false
        for arg in args {
            if hideNext {
                hideNext = false
                if !arg.hasPrefix("-") {
                    out.append(mask)
                    continue
                }
            }
            let dashed = arg.hasPrefix("-")
            let name = String(arg.drop { $0 == "-" })
            if let eq = name.firstIndex(of: "=") {
                let key = String(name[..<eq])
                let value = String(name[name.index(after: eq)...])
                if isSecret(key: key, value: value) || (dashed && isSecretFlagName(key)) {
                    let prefix = String(arg.prefix { $0 == "-" })
                    out.append("\(prefix)\(key)=\(mask)")
                    continue
                }
            } else if dashed, isSecretFlagName(name) {
                hideNext = true
            }
            out.append(Redactor.hasSecretShape(arg) ? mask : maskInside(arg))
        }
        return out
    }

    /// Hides the secret values inside one word and keeps the rest.
    private static func maskInside(_ text: String) -> String {
        let inner = Redactor.hideSecretValues(in: text, with: mask)
        return inner.replacingOccurrences(of: embeddedFlag, with: "$1\(mask)", options: .regularExpression)
    }
}
