import Foundation

/// Runs CLI tools with the same environment the old SwiftBar plugin pinned, so
/// every call targets the same VM as an interactive `colima` command.
enum Shell {
    static let home = FileManager.default.homeDirectoryForCurrentUser.path
    static let ctl = "\(home)/.local/bin/colima-ctl.sh"
    static let configPath = "\(home)/.config/colima/default/colima.yaml"
    static let busyPath = "\(home)/.cache/colima-bar/busy"

    static let env: [String: String] = {
        var e = ProcessInfo.processInfo.environment
        e["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        e["XDG_CONFIG_HOME"] = "\(home)/.config"
        return e
    }()

    struct Result {
        let status: Int32
        let out: String
        var ok: Bool { status == 0 }
    }

    /// Runs `args` off the main thread and returns its stdout. Kills the process
    /// after `timeout` seconds so a wedged docker socket can't stall the UI.
    static func run(_ args: [String], timeout: TimeInterval = 20) async -> Result {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                p.arguments = args
                p.environment = env
                let pipe = Pipe()
                p.standardOutput = pipe
                p.standardError = FileHandle.nullDevice
                p.standardInput = FileHandle.nullDevice
                do { try p.run() } catch {
                    cont.resume(returning: Result(status: -1, out: ""))
                    return
                }
                let timer = DispatchWorkItem { if p.isRunning { p.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                timer.cancel()
                cont.resume(returning: Result(status: p.terminationStatus,
                                              out: String(decoding: data, as: UTF8.self)))
            }
        }
    }

    /// Opens Terminal and runs `command` in a new window.
    static func inTerminal(_ command: String) {
        let escaped = command.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
        tell application "Terminal"
            activate
            do script "\(escaped)"
        end tell
        """
        Task { _ = await run(["osascript", "-e", script]) }
    }
}
