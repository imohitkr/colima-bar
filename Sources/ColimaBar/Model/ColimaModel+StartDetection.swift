import Foundation

extension ColimaModel {
    /// Whether a `ps` command line is a `colima start`/`restart` in progress for
    /// `profile`. `colima start -f` is a long-lived foreground supervisor (e.g.
    /// a launchd job), not a start in progress.
    nonisolated static func isStartInProgress(command: String, profile: String) -> Bool {
        let words = command.split(whereSeparator: \.isWhitespace).map(String.init)
        guard let i = words.firstIndex(where: { $0 == "colima" || $0.hasSuffix("/colima") }),
            i + 1 < words.count, ["start", "restart"].contains(words[i + 1])
        else { return false }
        if words.contains("-f") || words.contains("--foreground") { return false }
        var named: String?
        for (j, w) in words.enumerated() {
            if (w == "--profile" || w == "-p"), j + 1 < words.count { named = words[j + 1] }
            if w.hasPrefix("--profile=") { named = String(w.dropFirst("--profile=".count)) }
        }
        // `colima start NAME` also selects a profile.
        if named == nil, i + 2 < words.count, !words[i + 2].hasPrefix("-") { named = words[i + 2] }
        return (named ?? "default") == profile
    }

    /// Only this user's processes. Another account's `colima start` must not
    /// delay auto-start.
    nonisolated static func pgrepArguments(uid: uid_t) -> [String] {
        ["-U", String(uid), "-f", "colima (start|restart)"]
    }

    /// True while a `colima start` for this profile runs (e.g. from a terminal,
    /// which leaves no busy marker).
    nonisolated static func colimaStartRunning(_ profile: String) -> Bool {
        let pgrep = Shell.runSync("/usr/bin/pgrep", pgrepArguments(uid: getuid()))
        guard pgrep.ok else { return false }
        // pgrep prints pids only; check each command line for the profile.
        for pid in pgrep.out.split(separator: "\n") {
            let cmd = Shell.runSync("/bin/ps", ["-o", "command=", "-p", String(pid)]).out
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if isStartInProgress(command: cmd, profile: profile) { return true }
        }
        return false
    }
}
