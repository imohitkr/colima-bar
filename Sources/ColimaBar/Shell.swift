import Foundation

/// Filesystem locations. Colima keeps each profile in its own directory under
/// ~/.config/colima (the "default" profile in .../default).
enum Paths {
    static let home = FileManager.default.homeDirectoryForCurrentUser.path
    static let ctl = "\(home)/.local/bin/colima-ctl.sh"
    static let cacheDir = "\(home)/.cache/colima-bar"
    static let busy = "\(cacheDir)/busy"
    /// The stable socket every docker client is pointed at: ColimaBar's
    /// auto-start proxy while it runs, a symlink to Colima's socket otherwise.
    static let proxySocket = "\(cacheDir)/docker.sock"
    static let colimaLog = "/tmp/colima.err.log"
    static let testcontainersProps = "\(home)/.testcontainers.properties"

    static func profileDir(_ profile: String) -> String { "\(home)/.config/colima/\(profile)" }
    static func config(_ profile: String) -> String { "\(profileDir(profile))/colima.yaml" }
    static func socket(_ profile: String) -> String { "\(profileDir(profile))/docker.sock" }
    /// kubectl context Colima creates for a profile.
    static func kubeContext(_ profile: String) -> String { profile == "default" ? "colima" : "colima-\(profile)" }
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

    /// Runs `args` off the main thread and returns its stdout. Kills the process
    /// after `timeout` seconds so a wedged docker socket can't stall the UI.
    static func run(_ args: [String], timeout: TimeInterval = 20, extraEnv: [String: String] = [:]) async -> Result {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                p.arguments = args
                p.environment = env.merging(extraEnv) { $1 }
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

    /// Runs `command` in a new iTerm window, falling back to Terminal.app
    /// when iTerm isn't installed.
    static func inTerminal(_ command: String) {
        let escaped = command.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let iTerm = FileManager.default.fileExists(atPath: "/Applications/iTerm.app")
        let script = iTerm ? """
        tell application "iTerm"
            activate
            set w to (create window with default profile)
            tell current session of w to write text "\(escaped)"
        end tell
        """ : """
        tell application "Terminal"
            activate
            do script "\(escaped)"
        end tell
        """
        Task { _ = await run(["osascript", "-e", script]) }
    }
}
