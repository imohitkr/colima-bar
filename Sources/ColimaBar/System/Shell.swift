import AppKit
import Foundation

/// Thread-safe stdout accumulator for Shell.run.
/// `@unchecked Sendable`: `lock` guards `data`.
final class OutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func append(_ d: Data) { lock.withLock { data.append(d) } }
    var string: String { lock.withLock { String(decoding: data, as: UTF8.self) } }
}

/// Runs CLI tools with a pinned environment, so every call targets the same VM
/// as an interactive `colima` command, even when launched from Finder/launchd.
enum Shell {
    static let searchPath = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

    static let env: [String: String] = {
        var e = ProcessInfo.processInfo.environment
        e["PATH"] = searchPath
        // An inherited DOCKER_HOST (launchd's, which ColimaBar itself sets)
        // would mask docker contexts; colima-ctl.sh sets its own.
        e.removeValue(forKey: "DOCKER_HOST")
        e["XDG_CONFIG_HOME"] = "\(Paths.home)/.config"
        return e
    }()

    /// Absolute path of `tool` on the pinned search path, or nil if missing.
    static func which(_ tool: String) -> String? {
        searchPath.split(separator: ":").map { "\($0)/\(tool)" }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    struct Result {
        let status: Int32
        let out: String
        var ok: Bool { status == 0 }
    }

    /// Runs `args` off the main thread and returns its stdout. After `timeout`
    /// seconds it sends SIGTERM (colima-ctl.sh then cleans up and stops its
    /// children), and SIGKILL 10 s later. It returns when the process exits,
    /// even if an orphaned grandchild still holds the stdout pipe.
    /// colima-ctl.sh's stderr goes to Paths.ctlLog; other tools' is dropped.
    static func run(_ args: [String], timeout: TimeInterval = 20, extraEnv: [String: String] = [:]) async -> Result {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                p.arguments = args
                p.environment = env.merging(extraEnv) { $1 }
                let pipe = Pipe()
                p.standardOutput = pipe
                p.standardError = args.first == Paths.ctl ? ctlLogHandle() : FileHandle.nullDevice
                p.standardInput = FileHandle.nullDevice
                let out = OutputBuffer()
                // Only this handler reads the pipe, so reads never overlap.
                // Empty data means EOF: every writer has closed the pipe.
                let eof = DispatchSemaphore(value: 0)
                pipe.fileHandleForReading.readabilityHandler = { h in
                    let d = h.availableData
                    if d.isEmpty {
                        h.readabilityHandler = nil
                        eof.signal()
                    } else {
                        out.append(d)
                    }
                }
                let exited = DispatchSemaphore(value: 0)
                p.terminationHandler = { _ in exited.signal() }
                do { try p.run() } catch {
                    pipe.fileHandleForReading.readabilityHandler = nil
                    cont.resume(returning: Result(status: -1, out: ""))
                    return
                }
                if exited.wait(timeout: .now() + timeout) == .timedOut {
                    p.terminate()
                    if exited.wait(timeout: .now() + 10) == .timedOut {
                        kill(p.processIdentifier, SIGKILL)
                        exited.wait()
                    }
                }
                // Wait for the handler to read the last output and see EOF. An
                // orphaned grandchild may keep the pipe open, so wait 0.5 s at
                // most and drop any output that arrives later.
                if eof.wait(timeout: .now() + 0.5) == .timedOut {
                    pipe.fileHandleForReading.readabilityHandler = nil
                }
                cont.resume(returning: Result(status: p.terminationStatus, out: out.string))
            }
        }
    }

    /// Runs `executable` on the calling thread and waits for it to exit.
    /// It inherits the app's environment. Stderr is dropped, or read with
    /// stdout when `includeStderr` is true. The status is -1 if it can't start.
    /// Call it off the main thread only.
    static func runSync(_ executable: String, _ args: [String], includeStderr: Bool = false) -> Result {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = includeStderr ? pipe : FileHandle.nullDevice
        guard (try? p.run()) != nil else { return Result(status: -1, out: "") }
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        return Result(status: p.terminationStatus, out: out)
    }

    /// Append handle for Paths.ctlLog; the log is cut back once it passes 1 MB.
    private static func ctlLogHandle() -> FileHandle {
        let fm = FileManager.default
        if let size = (try? fm.attributesOfItem(atPath: Paths.ctlLog))?[.size] as? Int, size > 1 << 20 {
            try? fm.removeItem(atPath: Paths.ctlLog)
        }
        if !fm.fileExists(atPath: Paths.ctlLog) {
            try? fm.createDirectory(
                atPath: Paths.cacheDir, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            fm.createFile(atPath: Paths.ctlLog, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        guard let h = FileHandle(forWritingAtPath: Paths.ctlLog) else { return FileHandle.nullDevice }
        h.seekToEndOfFile()
        return h
    }

    /// Single-quotes a word for the shell.
    static func quote(_ s: String) -> String { "'\(s.replacingOccurrences(of: "'", with: "'\\''"))'" }

    /// The bundle ID of iTerm2. Launch Services finds the app by this ID in
    /// /Applications, ~/Applications or any other folder.
    static let iTermBundleID = "com.googlecode.iterm2"

    /// Runs `command` in a new iTerm window, falling back to Terminal.app
    /// when iTerm isn't installed.
    static func inTerminal(_ command: String) {
        let iTerm = NSWorkspace.shared.urlForApplication(withBundleIdentifier: iTermBundleID) != nil
        let script = terminalScript(command, iTerm: iTerm)
        Task { _ = await run(["osascript", "-e", script]) }
    }

    /// The AppleScript that runs `command` in a new iTerm window when `iTerm`
    /// is true, else in a new Terminal.app window.
    static func terminalScript(_ command: String, iTerm: Bool) -> String {
        let escaped = command.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return iTerm
            ? """
            tell application "iTerm"
                activate
                set w to (create window with default profile)
                tell current session of w to write text "\(escaped)"
            end tell
            """
            : """
            tell application "Terminal"
                activate
                do script "\(escaped)"
            end tell
            """
    }
}
