import Foundation

/// Filesystem locations. Colima keeps each profile in its own directory under
/// ~/.config/colima (the "default" profile in .../default).
enum Paths {
    static let home = FileManager.default.homeDirectoryForCurrentUser.path
    static let ctl = "\(home)/.local/bin/colima-ctl.sh"
    static let cacheDir = "\(home)/.cache/colima-bar"
    /// Busy marker colima-ctl.sh writes while a VM action runs, per profile.
    static func busy(_ profile: String) -> String { "\(cacheDir)/busy.\(profile)" }
    /// colima-ctl.sh's stderr (colima's own output included) when ColimaBar runs it.
    static let ctlLog = "\(cacheDir)/ctl.log"
    /// The stable socket every docker client is pointed at: ColimaBar's
    /// auto-start proxy while it runs, a symlink to Colima's socket otherwise.
    static let proxySocket = "\(cacheDir)/docker.sock"
    static let testcontainersProps = "\(home)/.testcontainers.properties"

    static func profileDir(_ profile: String) -> String { "\(home)/.config/colima/\(profile)" }
    static func config(_ profile: String) -> String { "\(profileDir(profile))/colima.yaml" }
    static func socket(_ profile: String) -> String { "\(profileDir(profile))/docker.sock" }
    /// kubectl context Colima creates for a profile.
    static func kubeContext(_ profile: String) -> String { profile == "default" ? "colima" : "colima-\(profile)" }
}

/// Thread-safe stdout accumulator for Shell.run.
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
                pipe.fileHandleForReading.readabilityHandler = { h in
                    let d = h.availableData
                    if !d.isEmpty { out.append(d) }
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
                // Let the last buffered output arrive, then stop reading. No
                // blocking read: an orphaned grandchild may keep the pipe open.
                usleep(100_000)
                pipe.fileHandleForReading.readabilityHandler = nil
                let fd = pipe.fileHandleForReading.fileDescriptor
                _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
                var buf = [UInt8](repeating: 0, count: 65536)
                while true {
                    let n = read(fd, &buf, buf.count)
                    if n <= 0 { break }
                    out.append(Data(buf[0..<n]))
                }
                cont.resume(returning: Result(status: p.terminationStatus, out: out.string))
            }
        }
    }

    /// Append handle for Paths.ctlLog; the log is cut back once it passes 1 MB.
    private static func ctlLogHandle() -> FileHandle {
        let fm = FileManager.default
        if let size = (try? fm.attributesOfItem(atPath: Paths.ctlLog))?[.size] as? Int, size > 1 << 20 {
            try? fm.removeItem(atPath: Paths.ctlLog)
        }
        if !fm.fileExists(atPath: Paths.ctlLog) {
            try? fm.createDirectory(atPath: Paths.cacheDir, withIntermediateDirectories: true)
            fm.createFile(atPath: Paths.ctlLog, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        guard let h = FileHandle(forWritingAtPath: Paths.ctlLog) else { return FileHandle.nullDevice }
        h.seekToEndOfFile()
        return h
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
