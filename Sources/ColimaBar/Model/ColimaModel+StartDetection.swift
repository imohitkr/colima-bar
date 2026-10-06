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
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        p.arguments = pgrepArguments(uid: getuid())
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return false }
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return false }
        // pgrep prints pids only; check each command line for the profile.
        for pid in out.split(separator: "\n") {
            let ps = Process()
            ps.executableURL = URL(fileURLWithPath: "/bin/ps")
            ps.arguments = ["-o", "command=", "-p", String(pid)]
            let pp = Pipe()
            ps.standardOutput = pp
            ps.standardError = FileHandle.nullDevice
            guard (try? ps.run()) != nil else { continue }
            let cmd = String(decoding: pp.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            ps.waitUntilExit()
            if isStartInProgress(command: cmd, profile: profile) { return true }
        }
        return false
    }
}
