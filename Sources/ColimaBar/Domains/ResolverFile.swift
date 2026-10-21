import Foundation

/// The file `/etc/resolver/<suffix>` that sends the names of the custom suffix
/// to the DNS responder of ColimaBar, and the root shell that writes and
/// removes it. Pure: it builds text and runs nothing.
///
/// The shell gets only values that this type validates: a suffix that passes
/// `DomainSuffix.problem`, a fixed folder, a fixed marker and an integer
/// port. Each goes through `shellQuote`, then the whole text through
/// `appleScript`. The shell never writes or removes a file that lacks the
/// marker on its first line, or that is a symlink.
enum ResolverFile {
    static let dir = "/etc/resolver"
    static let marker = "# Managed by ColimaBar (com.imohitkr.ColimaBar). ColimaBar changes and removes this file."
    /// The exit status of the shell for a file that another tool owns.
    static let foreignExit: Int32 = 3
    /// The shell prints it to stderr before it exits with `foreignExit`. `osascript` reports a failed script with its own status, so the text is the reliable sign.
    static let foreignToken = "colimabar-foreign"
    static let portRange = 1024...65535
    /// The shell writes the new file as `.SUFFIX.colimabar-tmp` and renames it. A trap removes it again if the shell fails.
    static let tempPrefix = "."
    static let tempSuffix = ".colimabar-tmp"

    static func path(_ suffix: String, dir: String = dir) -> String { "\(dir)/\(suffix)" }

    static func content(port: Int) -> String { "\(marker)\nnameserver 127.0.0.1\nport \(port)\n" }

    /// The port of the `port N` line of a file that we wrote, or nil.
    static func port(in text: String) -> Int? {
        for line in text.split(separator: "\n") where line.hasPrefix("port ") {
            return Int(line.dropFirst(5)).flatMap { portRange.contains($0) ? $0 : nil }
        }
        return nil
    }

    /// True when the first line is the marker.
    static func isOurs(_ text: String) -> Bool {
        text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) == marker
    }

    /// `'…'` with each `'` written as `'\''`.
    static func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    /// The /bin/sh text that installs `new` (exit 3 for a foreign file or a
    /// link), then removes `old` (only if ours, a regular file). The new file
    /// goes first, so a failure never leaves the user without a file. nil when a suffix
    /// or the port is not valid: nothing reaches a shell then.
    static func shellCommand(dir: String = dir, new: String?, old: String?, port: Int) -> String? {
        let newName = new.map(DomainSuffix.valid)
        let oldName = old.map(DomainSuffix.valid)
        if newName == .some(nil) || oldName == .some(nil) { return nil }
        let n = newName.flatMap { $0 } ?? ""
        let o = oldName.flatMap { $0 } ?? ""
        if !n.isEmpty, !portRange.contains(port) { return nil }
        if n.isEmpty, o.isEmpty { return nil }
        let p = n.isEmpty ? 0 : port
        return [
            "set -e",
            "D=\(shellQuote(dir)); N=\(shellQuote(n)); O=\(shellQuote(o)); M=\(shellQuote(marker)); P=\(p); T=''",
            "trap '[ -z \"$T\" ] || /bin/rm -f \"$T\"' EXIT",
            "ours() { [ -f \"$1\" ] && [ ! -L \"$1\" ] && [ \"$(/usr/bin/head -n 1 \"$1\")\" = \"$M\" ]; }",
            "if [ -n \"$N\" ]; then",
            "  if [ -L \"$D/$N\" ] || { [ -e \"$D/$N\" ] && ! ours \"$D/$N\"; }; then /bin/echo \(foreignToken) >&2; exit \(foreignExit); fi",
            "  /bin/mkdir -p \"$D\"",
            "  T=\"$D/\(tempPrefix)$N\(tempSuffix)\"; /bin/rm -f \"$T\"",
            "  /usr/bin/printf '%s\\nnameserver 127.0.0.1\\nport %s\\n' \"$M\" \"$P\" > \"$T\"",
            "  /bin/chmod 0644 \"$T\"",
            "  [ \"$(/usr/bin/id -u)\" -ne 0 ] || /usr/sbin/chown root:wheel \"$T\"",
            "  /bin/mv -f \"$T\" \"$D/$N\"; T=''",
            "fi",
            "if [ -n \"$O\" ] && [ \"$O\" != \"$N\" ] && ours \"$D/$O\"; then /bin/rm -f \"$D/$O\"; fi",
        ].joined(separator: "\n")
    }

    /// `do shell script "<escaped>" with administrator privileges`. It escapes
    /// `\` and `"`, and writes a line break as `\n`.
    static func appleScript(_ shell: String) -> String {
        let escaped = shell.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        return "do shell script \"\(escaped)\" with administrator privileges"
    }
}
