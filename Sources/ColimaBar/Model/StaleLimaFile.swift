import Foundation

/// A pid file of Lima that Lima cannot use. `colima-ctl.sh stale-files`
/// prints one line for each: `reason<TAB>path<TAB>pid`.
struct StaleLimaFile: Equatable, Sendable {
    enum Reason: String, Sendable {
        /// The file has no PID.
        case invalid
        /// No process has the PID. Lima removes the file at the next start.
        case gone
        /// Another process has the PID. A force stop of Lima would kill it.
        case reused
    }

    let reason: Reason
    let path: String
    let pid: String

    /// The lines of the script. A line with an unknown reason, or with a path
    /// outside `limaDir`, is dropped: ColimaBar shows and repairs only files
    /// in Lima's folder and the pid file of the Colima daemon (`daemonPidFile`).
    static func parse(_ output: String, limaDir: String, daemonPidFile: String? = nil) -> [StaleLimaFile] {
        scan(output, limaDir: limaDir, daemonPidFile: daemonPidFile).files
    }

    /// Like `parse`, and counts the non-empty lines that it dropped.
    static func scan(
        _ output: String, limaDir: String, daemonPidFile: String? = nil
    ) -> (files: [StaleLimaFile], dropped: Int) {
        let root = limaDir.hasSuffix("/") ? limaDir : limaDir + "/"
        var files: [StaleLimaFile] = []
        var dropped = 0
        for line in output.split(whereSeparator: \.isNewline) where !line.allSatisfy(\.isWhitespace) {
            let f = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
            guard f.count == 3, let reason = Reason(rawValue: f[0]),
                f[1] == daemonPidFile || (f[1].hasPrefix(root) && !f[1].split(separator: "/").contains(".."))
            else {
                dropped += 1
                continue
            }
            files.append(StaleLimaFile(reason: reason, path: f[1], pid: f[2]))
        }
        return (files, dropped)
    }

    /// The path below Lima's folder, for example "colima/ha.pid".
    func name(limaDir: String) -> String {
        let root = limaDir.hasSuffix("/") ? limaDir : limaDir + "/"
        return path.hasPrefix(root) ? String(path.dropFirst(root.count)) : path
    }
}
