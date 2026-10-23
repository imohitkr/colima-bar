import Darwin
import Foundation

/// Runs the repository's shell scripts in a temporary HOME with stub tools.
///
/// `copy(_:)` writes a copy of a script whose `export PATH=` line puts the
/// stub folder first. Thus the stub `osascript`, `colima` and `docker` run
/// (and `kubectl`) instead of the real tools: no dialog reaches the screen, and no VM or
/// docker context changes. Each stub appends its arguments to `log`.
///
/// `STUB_OSASCRIPT_OUT` is the text that the stub `osascript` prints, the
/// button of a dialog with several buttons ("Continue", "Release Notes").
/// `STUB_OSASCRIPT_ERR` is the text that it prints to stderr, for example
/// "execution error: User canceled. (-128)".
/// The stub `open` logs its arguments and opens nothing.
///
/// Stub exit codes: `STUB_OSASCRIPT_EXIT` (default 0: the user clicked OK)
/// and `STUB_COLIMA_STATUS` for `colima status` (default 1: stopped).
/// `STUB_COLIMA_SSH_OUT` is the text that `colima ssh` prints (for example the
/// output of fstrim) and `STUB_COLIMA_SSH_EXIT` its exit status (default 0).
/// `STUB_DOCKER_EXIT` is the exit status of the stub `docker` (default 0).
/// `STUB_DOCKER_PROBE` is a file: the stub `docker` logs "docker saw marker"
/// when it exists. `STUB_OSASCRIPT_STOPS_VM=1` makes `colima status` fail
/// after the first dialog, like a VM that stops while the dialog is open.
/// If `STUB_DELETE_DIR` is set, `colima delete` removes that folder, like
/// the real `colima delete` removes the profile folder. The stub `pgrep`
/// finds no process and logs nothing, so a real `colima start` on the Mac
/// does not change a test.
///
/// The stub `security` logs its arguments and changes no keychain. For
/// `find-certificate` it prints `STUB_SECURITY_FIND`. `STUB_SECURITY_DELETE_EXIT`
/// is the exit status of `delete-certificate` (default 0).
///
/// The stub `ps` answers `-o command= -p PID` and `-o etime= -p PID` from a
/// table. It starts empty: no process runs. `stubProcesses(_:)` fills it, for
/// the owner checks of the lock, the busy marker and the pid files of Lima.
final class ScriptSandbox {
    let root: String
    let home: String
    let bin: String
    let log: String
    /// The table of the stub `ps`: PID, etime and command, tab separated.
    let processTable: String

    /// A process that the stub `ps` knows.
    struct FakeProcess {
        let pid: Int
        /// How long the process runs, in seconds.
        let age: Int
        let command: String

        /// The `etime` text of `ps`: `[[DD-]HH:]MM:SS`.
        var etime: String {
            let d = age / 86400, h = age % 86400 / 3600, m = age % 3600 / 60, s = age % 60
            if d > 0 { return String(format: "%d-%02d:%02d:%02d", d, h, m, s) }
            if h > 0 { return String(format: "%02d:%02d:%02d", h, m, s) }
            return String(format: "%02d:%02d", m, s)
        }
    }

    /// The repository root, found from this file's path.
    static let repo = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()

    init() throws {
        root = NSTemporaryDirectory() + "cb-script-\(getpid())-\(UUID().uuidString.prefix(8))"
        home = root + "/home"
        bin = root + "/bin"
        log = root + "/calls.log"
        processTable = root + "/processes.tsv"
        let fm = FileManager.default
        try fm.createDirectory(atPath: home, withIntermediateDirectories: true)
        try fm.createDirectory(atPath: bin, withIntermediateDirectories: true)
        try Self.put("", to: log)
        try stub(
            "osascript",
            """
            printf 'osascript %s\\n' "$*" >> "\(log)"
            [ -n "${STUB_OSASCRIPT_OUT:-}" ] && printf '%s\\n' "$STUB_OSASCRIPT_OUT"
            [ -n "${STUB_OSASCRIPT_ERR:-}" ] && printf '%s\\n' "$STUB_OSASCRIPT_ERR" >&2
            [ -n "${STUB_OSASCRIPT_STOPS_VM:-}" ] && : > "\(root)/vm-stopped"
            exit "${STUB_OSASCRIPT_EXIT:-0}"
            """)
        // The release notes button opens a page. The stub only logs the URL.
        try stub("open", "printf 'open %s\\n' \"$*\" >> \"\(log)\"\nexit 0")
        try stub(
            "colima",
            """
            printf 'colima %s\\n' "$*" >> "\(log)"
            [ "$1" = status ] && { [ -e "\(root)/vm-stopped" ] && exit 1; exit "${STUB_COLIMA_STATUS:-1}"; }
            [ "$1" = ssh ] && { [ -n "${STUB_COLIMA_SSH_OUT:-}" ] && printf '%s\\n' "$STUB_COLIMA_SSH_OUT"; exit "${STUB_COLIMA_SSH_EXIT:-0}"; }
            [ "$1" = delete ] && [ -n "${STUB_DELETE_DIR:-}" ] && rm -rf "$STUB_DELETE_DIR"
            exit 0
            """)
        // STUB_DOCKER_PROBE is a file path. The stub logs "docker saw marker" when it exists.
        try stub(
            "docker",
            """
            printf 'docker %s\\n' "$*" >> "\(log)"
            [ -n "${STUB_DOCKER_PROBE:-}" ] && [ -e "$STUB_DOCKER_PROBE" ] && printf 'docker saw marker\\n' >> "\(log)"
            exit "${STUB_DOCKER_EXIT:-0}"
            """)
        // The uninstall script looks for the certificate authority of HTTPS and deletes it.
        try stub(
            "security",
            """
            printf 'security %s\\n' "$*" >> "\(log)"
            case "$1" in
              find-certificate) [ -n "${STUB_SECURITY_FIND:-}" ] && printf '%s\\n' "$STUB_SECURITY_FIND"; exit 0 ;;
              delete-certificate) exit "${STUB_SECURITY_DELETE_EXIT:-0}" ;;
            esac
            exit 0
            """)
        // colima-ctl.sh k8s on switches the kubectl context.
        try stub("kubectl", "printf 'kubectl %s\\n' \"$*\" >> \"\(log)\"\nexit 0")
        // colima-ctl.sh looks for a `colima start` in progress.
        try stub("pgrep", "exit 1")
        // The owner checks of colima-ctl.sh ask `ps` about a PID.
        try Self.put("", to: processTable)
        try stub(
            "ps",
            """
            col=""; pid=""
            while [ $# -gt 0 ]; do
              case "$1" in -o) col="$2"; shift ;; -p) pid="$2"; shift ;; esac
              shift
            done
            awk -F'\t' -v p="$pid" -v c="$col" '$1 == p { if (c == "command=") print $3; else if (c == "etime=") print $2; found = 1 } END { exit found ? 0 : 1 }' "\(processTable)"
            """)
    }

    deinit { try? FileManager.default.removeItem(atPath: root) }

    /// Writes a file in one pass: open, write, close. `String.write(atomically:)`
    /// writes a temporary file, syncs it to the disk and renames it. A sandbox
    /// makes dozens of files in the body of a test, which runs on a thread of the
    /// Swift pool, and a runner with a slow disk then holds all those threads
    /// in fsync. Nothing reads a sandbox file while it is written, and a power
    /// cut makes no sandbox matter, so the plain write is enough.
    static func put(_ text: String, to path: String, mode: mode_t = 0o644) throws {
        let fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, mode)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(fd) }
        guard fchmod(fd, mode) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var bytes = Array(text.utf8)[...]
        while !bytes.isEmpty {
            let n = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
            if n < 0, errno == EINTR { continue }
            guard n > 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            bytes = bytes.dropFirst(n)
        }
    }

    /// Writes an executable stub tool.
    func stub(_ tool: String, _ body: String) throws {
        try Self.put("#!/bin/bash\n" + body + "\n", to: "\(bin)/\(tool)", mode: 0o755)
    }

    /// Sets the processes that the stub `ps` knows. Any other PID has no process.
    func stubProcesses(_ processes: [FakeProcess]) throws {
        let text = processes.map { "\($0.pid)\t\($0.etime)\t\($0.command)" }.joined(separator: "\n") + "\n"
        try Self.put(text, to: processTable)
    }

    /// Sets the modification time of a file or folder to `seconds` ago.
    func setAge(_ path: String, seconds: TimeInterval) throws {
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -seconds)], ofItemAtPath: path)
    }

    /// A copy of `scripts/NAME` that finds the stub tools first. It throws
    /// if the script has no `export PATH="` line to patch.
    func copy(_ name: String) throws -> String {
        let text = try String(contentsOf: Self.repo.appendingPathComponent("scripts/\(name)"), encoding: .utf8)
        let marker = "export PATH=\""
        guard text.contains("\n" + marker) else { throw SandboxError.noPathLine(name) }
        let patched = text.replacingOccurrences(of: "\n" + marker, with: "\n" + marker + bin + ":")
        let path = "\(root)/\(name)"
        try Self.put(patched, to: path)
        return path
    }

    enum SandboxError: Error { case noPathLine(String) }

    /// Runs `bash ARGS` with HOME in the sandbox and the stub folder first
    /// on PATH. Returns the exit status and stdout. The process waits block,
    /// so they run on their own thread (see onOwnThread).
    func bash(_ args: [String], env: [String: String] = [:]) async throws -> (status: Int32, out: String) {
        let environment = ["HOME": home, "PATH": "\(bin):/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "C"]
            .merging(env) { $1 }
        return try await onOwnThread { () -> Result<(status: Int32, out: String), any Error> in
            Result {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/bin/bash")
                p.arguments = args
                p.environment = environment
                let out = Pipe()
                p.standardOutput = out
                p.standardError = FileHandle.nullDevice
                p.standardInput = FileHandle.nullDevice
                try p.run()
                let data = out.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                return (p.terminationStatus, String(decoding: data, as: UTF8.self))
            }
        }.get()
    }

    /// Runs a copy of scripts/colima-ctl.sh for `profile`, as ColimaBar does.
    func ctl(
        _ args: [String], profile: String = "work", env: [String: String] = [:]
    ) async throws -> (status: Int32, out: String) {
        try await bash(
            [copy("colima-ctl.sh")] + args,
            env: ["COLIMABAR_PROFILE": profile, "COLIMABAR_APP": "1"].merging(env) { $1 })
    }

    /// The stub calls so far, one line each.
    var calls: [String] {
        ((try? String(contentsOfFile: log, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }

    /// True when the script left no lock folder and no busy marker.
    var leavesNoLockOrBusyMarker: Bool {
        let left = (try? FileManager.default.contentsOfDirectory(atPath: home + "/.cache/colima-bar")) ?? []
        return !left.contains { $0.hasPrefix("lock.") || $0.hasPrefix("busy.") }
    }

    /// Writes a file below HOME, for example ".config/colima/work/colima.yaml".
    func write(_ relative: String, _ text: String) throws {
        let path = "\(home)/\(relative)"
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try Self.put(text, to: path)
    }
}
