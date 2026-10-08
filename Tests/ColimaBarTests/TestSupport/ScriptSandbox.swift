import Foundation

/// Runs the repository's shell scripts in a temporary HOME with stub tools.
///
/// `copy(_:)` writes a copy of a script whose `export PATH=` line puts the
/// stub folder first. Thus the stub `osascript`, `colima` and `docker` run
/// (and `kubectl`) instead of the real tools: no dialog reaches the screen, and no VM or
/// docker context changes. Each stub appends its arguments to `log`.
///
/// Stub exit codes: `STUB_OSASCRIPT_EXIT` (default 0: the user clicked OK)
/// and `STUB_COLIMA_STATUS` for `colima status` (default 1: stopped).
/// If `STUB_DELETE_DIR` is set, `colima delete` removes that folder, like
/// the real `colima delete` removes the profile folder. The stub `pgrep`
/// finds no process and logs nothing, so a real `colima start` on the Mac
/// does not change a test.
final class ScriptSandbox {
    let root: String
    let home: String
    let bin: String
    let log: String

    /// The repository root, found from this file's path.
    static let repo = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()

    init() throws {
        root = NSTemporaryDirectory() + "cb-script-\(getpid())-\(UUID().uuidString.prefix(8))"
        home = root + "/home"
        bin = root + "/bin"
        log = root + "/calls.log"
        let fm = FileManager.default
        try fm.createDirectory(atPath: home, withIntermediateDirectories: true)
        try fm.createDirectory(atPath: bin, withIntermediateDirectories: true)
        fm.createFile(atPath: log, contents: nil)
        try stub(
            "osascript",
            """
            printf 'osascript %s\\n' "$*" >> "\(log)"
            exit "${STUB_OSASCRIPT_EXIT:-0}"
            """)
        try stub(
            "colima",
            """
            printf 'colima %s\\n' "$*" >> "\(log)"
            [ "$1" = status ] && exit "${STUB_COLIMA_STATUS:-1}"
            [ "$1" = delete ] && [ -n "${STUB_DELETE_DIR:-}" ] && rm -rf "$STUB_DELETE_DIR"
            exit 0
            """)
        try stub("docker", "printf 'docker %s\\n' \"$*\" >> \"\(log)\"\nexit 0")
        // colima-ctl.sh k8s on switches the kubectl context.
        try stub("kubectl", "printf 'kubectl %s\\n' \"$*\" >> \"\(log)\"\nexit 0")
        // colima-ctl.sh looks for a `colima start` in progress.
        try stub("pgrep", "exit 1")
    }

    deinit { try? FileManager.default.removeItem(atPath: root) }

    /// Writes an executable stub tool.
    func stub(_ tool: String, _ body: String) throws {
        let path = "\(bin)/\(tool)"
        try ("#!/bin/bash\n" + body + "\n").write(toFile: path, atomically: true, encoding: .utf8)
        chmod(path, 0o755)
    }

    /// A copy of `scripts/NAME` that finds the stub tools first. It throws
    /// if the script has no `export PATH="` line to patch.
    func copy(_ name: String) throws -> String {
        let text = try String(contentsOf: Self.repo.appendingPathComponent("scripts/\(name)"), encoding: .utf8)
        let marker = "export PATH=\""
        guard text.contains("\n" + marker) else { throw SandboxError.noPathLine(name) }
        let patched = text.replacingOccurrences(of: "\n" + marker, with: "\n" + marker + bin + ":")
        let path = "\(root)/\(name)"
        try patched.write(toFile: path, atomically: true, encoding: .utf8)
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

    /// The stub calls so far, one line each.
    var calls: [String] {
        ((try? String(contentsOfFile: log, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }

    /// Writes a file below HOME, for example ".config/colima/work/colima.yaml".
    func write(_ relative: String, _ text: String) throws {
        let path = "\(home)/\(relative)"
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try text.write(toFile: path, atomically: true, encoding: .utf8)
    }
}
