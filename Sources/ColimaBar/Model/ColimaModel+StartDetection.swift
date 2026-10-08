import Foundation

extension ColimaModel {
    /// Whether a `ps` command line is a `colima start`/`restart` in progress for
    /// `profile`. colima-ctl.sh has the same rules in `start_words`:
    /// - `colima start -f` is a long-lived foreground supervisor (e.g. a
    ///   launchd job), not a start in progress. For `colima restart`, `-f`
    ///   means `--force` and counts.
    /// - The profile is the value of `--profile` or `-p` (also `--profile=NAME`
    ///   and `-p=NAME`). Else it is the first word after `start` or `restart`
    ///   that is not a flag and not the value of a flag. Else it is default.
    /// - Colima reads `colima` as default and removes a `colima-` prefix.
    nonisolated static func isStartInProgress(command: String, profile: String) -> Bool {
        let words = command.split(whereSeparator: \.isWhitespace).map(String.init)
        guard let i = words.firstIndex(where: { $0 == "colima" || $0.hasSuffix("/colima") }),
            i + 1 < words.count, ["start", "restart"].contains(words[i + 1])
        else { return false }
        let verb = words[i + 1]
        var named: String?
        var first: String?
        var j = i + 2
        while j < words.count {
            let w = words[j]
            if w == "-f" || w == "--foreground" {
                if verb == "start" { return false }
            } else if w == "--profile" || w == "-p" {
                j += 1
                if j < words.count { named = words[j] }
            } else if w.hasPrefix("--profile=") {
                named = String(w.dropFirst("--profile=".count))
            } else if w.hasPrefix("-p=") {
                named = String(w.dropFirst("-p=".count))
            } else if startValueFlags.contains(w) {
                j += 1
            } else if !w.hasPrefix("-"), first == nil {
                first = w
            }
            j += 1
        }
        var name = named.flatMap { $0.isEmpty ? nil : $0 } ?? first ?? "default"
        if name == "colima" { name = "default" }
        if name.hasPrefix("colima-") { name = String(name.dropFirst("colima-".count)) }
        return name == profile
    }

    /// The flags of `colima start` that take a value in the next word
    /// (`colima start --help`). `--cpu 4` is one flag and its value.
    nonisolated static let startValueFlags: Set<String> = [
        "-a", "--arch", "--cpu-type", "-c", "--cpu", "--cpus", "-d", "--disk", "-i", "--disk-image", "-n", "--dns",
        "--dns-host", "--downloader", "--editor", "--env", "--gateway-address", "--hostname", "--k3s-arg",
        "--k3s-listen-port", "--kubernetes-version", "-m", "--memory", "--model-runner", "-V", "--mount",
        "--mount-type", "--network-interface", "--network-mode", "--port-forwarder", "--root-disk", "-r", "--runtime",
        "--ssh-port", "-t", "--vm-type",
    ]

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
