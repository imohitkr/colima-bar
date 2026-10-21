import Foundation

/// The json log files of the containers in the VM. Docker's json-file driver
/// writes /var/lib/docker/containers/ID/ID-json.log, mode 0640, in a folder
/// that only root reads. Thus the listing runs with `sudo -n`.
enum LogFileSizes {
    static let folder = "/var/lib/docker/containers"
    /// The text before the end of the listing. The script prints it last.
    static let statusMarker = "colimabar-status="
    /// A listing has at most this many lines. More lines are not read.
    static let maxLines = 2048
    /// A constant: no container text reaches a shell.
    static let vmScript =
        #"for f in /var/lib/docker/containers/*/*-json.log; do [ -f "$f" ] && stat -c '%s %n' "$f"; done; echo colimabar-status=0"#

    static func command(profile: String) -> [String] {
        ["colima", "ssh", "--profile", profile, "--", "sudo", "-n", "sh", "-c", vmScript]
    }

    /// The size by full container ID, or nil when the marker is missing
    /// (`sudo` or `colima ssh` failed). `colima ssh` exits with 1 for every
    /// failure of the remote command, so the marker decides. A line counts
    /// only if its path is exactly folder/ID/ID-json.log with the same
    /// 64-character lowercase hex ID twice.
    static func parse(status: Int32, out: String) -> [String: Int64]? {
        guard status == 0 else { return nil }
        var sizes: [String: Int64] = [:]
        var sawMarker = false
        var lines = 0
        for line in out.split(separator: "\n", omittingEmptySubsequences: true) {
            if line == "\(statusMarker)0" {
                sawMarker = true
                break
            }
            lines += 1
            if lines > maxLines { continue }
            let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, let size = Int64(parts[0]), size >= 0, let id = id(ofPath: String(parts[1]))
            else { continue }
            sizes[id] = size
        }
        return sawMarker ? sizes : nil
    }

    /// The last line of the error output of a failed listing, cut to 120
    /// characters. The output has the text of `sudo` or `colima ssh`.
    static func failureDetail(_ out: String) -> String {
        let line = out.split(whereSeparator: \.isNewline).last.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        return String(line.prefix(120))
    }

    /// True for 64 characters of 0-9 and a-f.
    static func isValidID(_ id: String) -> Bool {
        id.utf8.count == 64 && id.utf8.allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66) }
    }

    /// The log file of a container, or nil for an ID that is not valid.
    static func path(id: String) -> String? {
        isValidID(id) ? "\(folder)/\(id)/\(id)-json.log" : nil
    }

    private static func id(ofPath path: String) -> String? {
        let prefix = folder + "/"
        guard path.hasPrefix(prefix) else { return nil }
        let rest = path.dropFirst(prefix.count)
        guard let slash = rest.firstIndex(of: "/") else { return nil }
        let id = String(rest[..<slash])
        guard self.path(id: id) == path else { return nil }
        return id
    }
}
