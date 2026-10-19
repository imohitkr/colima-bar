import Darwin
import Foundation

/// All the I/O of the diagnostics file. Each function reads one part and
/// returns its outcome. None of them changes anything, and none of them can
/// start the VM: they use no proxy socket, only the own socket of Colima
/// while the VM runs, and tools that do not call the daemon.
enum DiagnosticsProbe {
    typealias Outcome = DiagnosticsSection.Outcome

    /// ColimaBar's own log lines. `process ==` leaves out the test helper,
    /// which logs with the same subsystem. The subsystem is the bundle ID.
    private static let logPredicate = "subsystem == \"com.imohitkr.ColimaBar\" AND process == \"ColimaBar\""

    // MARK: - Tools

    /// Why a tool gave no output: not found, not executable, a time-out or
    /// an exit status. With the last line of its output (stderr is part of
    /// it when the call asked for it), cut to 200 characters.
    static func failure(status: Int32, output: String = "") -> String {
        var why: String
        switch status {
        case -1, 127: why = "not found"
        case 126: why = "not executable"
        case 15: why = "timed out"
        default: why = "exit \(status)"
        }
        let last = output.split(whereSeparator: \.isNewline).last.map {
            String($0.trimmingCharacters(in: .whitespaces).prefix(200))
        }
        if let last, !last.isEmpty { why += ": " + last }
        return why
    }

    static func failure(_ r: Shell.Result) -> String { failure(status: r.status, output: r.out) }

    /// The output of a tool, or the reason that it failed. The reason has the
    /// last line of stderr, so `includeStderr` is on by default.
    static func command(
        _ args: [String], timeout: TimeInterval, extraEnv: [String: String] = [:], includeStderr: Bool = true
    ) async -> Outcome {
        let r = await Shell.run(args, timeout: timeout, extraEnv: extraEnv, includeStderr: includeStderr)
        return r.ok ? .ok(r.out.trimmingCharacters(in: .whitespacesAndNewlines)) : .failed(failure(r))
    }

    /// The paths and versions of the tools, one line each.
    static func toolsText(_ t: DoctorInputs.Tools) -> String {
        func line(_ name: String, _ path: String?, _ version: String?) -> String {
            guard let path else { return "\(name): not found" }
            return "\(name): \(path), version \(version ?? "not read")"
        }
        let v = t.versions
        return [
            line("colima", t.colimaPath, v.colima), line("limactl", t.limactlPath, v.lima),
            line("docker", t.dockerPath, v.docker), "macOS: \(v.macOS ?? "unknown")",
        ].joined(separator: "\n")
    }

    /// Runs the part that needs no model data.
    static func run(_ part: DiagnosticsPart, profile: String) async -> Outcome {
        switch part {
        case .app: return app()
        case .routes: return await routes()
        case .colimaList: return await colimaList()
        case .colimaStatus: return await colimaStatus(profile: profile)
        case .lima: return await lima()
        case .engine: return await engine(profile: profile)
        case .colimaConfig: return colimaConfig(profile: profile)
        case .appLog: return await appLog()
        case .ctlLog: return ctlLog()
        case .limaLog: return limaLog(profile: profile)
        case .crashReports: return crashReports()
        case .settings, .state, .tools, .doctor, .goodStarts: return .failed("this part needs the model")
        }
    }

    // MARK: - Mac and app

    static func app() -> Outcome {
        let info = Bundle.main.infoDictionary ?? [:]
        let power = PowerState.read()
        let p = ProcessInfo.processInfo
        let lines = [
            "Version: \(info["CFBundleShortVersionString"] as? String ?? "dev") (build \(info["CFBundleVersion"] as? String ?? "?"))",
            "Bundle: \(Bundle.main.bundlePath)",
            "macOS: \(p.operatingSystemVersionString)",
            "Model: \(sysctlString("hw.model") ?? "unknown")",
            "Architecture: \(sysctlString("hw.machine") ?? "unknown")\(sysctlInt("sysctl.proc_translated") == 1 ? " (runs under Rosetta)" : "")",
            "CPUs: \(p.activeProcessorCount)",
            "Memory: \(ByteFormat.bytes(Double(p.physicalMemory)))",
            "Power: \(power.onBattery ? "battery" : "charger"), Low Power Mode \(power.lowPowerMode ? "on" : "off"), \(power.isHot ? "hot" : "not hot")",
        ]
        return .ok(lines.joined(separator: "\n"))
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return nil }
        return text(buf)
    }

    /// The text of a C buffer, up to the first zero byte.
    private static func text(_ buf: [CChar]) -> String {
        String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    private static func sysctlInt(_ name: String) -> Int? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return Int(value)
    }

    /// Which of the variables that move the Colima, Lima or docker folders
    /// are set. Only the names show, never the values.
    static func environmentNames(_ env: [String: String]) -> [String] {
        ["COLIMA_HOME", "LIMA_HOME", "XDG_CONFIG_HOME", "DOCKER_CONFIG"].map { name in
            "\(name): \((env[name] ?? "").isEmpty ? "not set" : "set")"
        }
    }

    // MARK: - Colima, Lima and docker

    @MainActor
    static func routes() async -> Outcome {
        async let status = Routing.status()
        async let contexts = Shell.run(
            ["docker", "context", "ls", "--format", "{{.Name}}\t{{.DockerEndpoint}}\t{{.Current}}\t{{.Error}}"],
            timeout: 8, includeStderr: true)
        let s = await status
        let c = await contexts
        let currentContext = Routing.currentContext()
        let current = currentContext.map { $0.isEmpty ? "default" : $0 } ?? "unreadable"
        var problems: [String] = []
        if currentContext == nil { problems.append("the docker config file is not readable") }
        if let why = s.launchdError { problems.append("launchctl getenv failed (\(why))") }
        if !c.ok { problems.append("docker context ls failed (\(failure(c)))") }
        var lines = [
            "Current docker context: \(current)",
            "colimabar context is current: \(s.context)",
            "launchd DOCKER_HOST: \(s.launchdError.map { "not read (\($0))" } ?? (s.launchdHost.isEmpty ? "not set" : s.launchdHost))",
            "testcontainers docker.host: \(s.testcontainersHost ?? "not set")",
            "/var/run/docker.sock points to ColimaBar: \(s.varRun)",
            "docker context ls (name, endpoint, current, error):",
        ]
        lines += c.ok ? c.out.split(separator: "\n").map { "  " + $0 } : ["  failed (\(failure(c)))"]
        let text = lines.joined(separator: "\n")
        return problems.isEmpty ? .ok(text) : .partial(text, problems.joined(separator: "; "))
    }

    static func colimaList() async -> Outcome {
        await command(["colima", "list", "-j"], timeout: 10)
    }

    static func colimaStatus(profile: String) async -> Outcome {
        await command(["colima", "status", "-j", "--profile", profile], timeout: 8, includeStderr: true)
    }

    static func lima() async -> Outcome {
        await command(
            ["limactl", "list", "--format", "{{.Name}} | {{.Status}} | {{.VMType}} | {{.Arch}} | {{.Errors}}"],
            timeout: 5, extraEnv: ["LIMA_HOME": Paths.limaDir])
    }

    /// `GET /version` on the own socket of Colima. It never uses a proxy
    /// socket, because a request there can start the VM.
    static func engine(profile: String) async -> Outcome {
        let api = DockerAPI(socketPath: Paths.socket(profile))
        guard let r = await api.get("/version", timeout: 5) else { return .failed("no reply from the socket") }
        guard r.ok, let json = try? JSONSerialization.jsonObject(with: r.body) as? [String: Any] else {
            return .failed("HTTP \(r.status)")
        }
        var lines: [String] = []
        for k in ["Version", "ApiVersion", "MinAPIVersion", "GitCommit", "GoVersion", "Os", "Arch", "KernelVersion"] {
            if let v = json[k] { lines.append("\(k): \(v)") }
        }
        let components = (json["Components"] as? [[String: Any]] ?? []).compactMap { c -> String? in
            guard let n = c["Name"] as? String else { return nil }
            return "\(n) \(c["Version"] as? String ?? "?")"
        }
        if !components.isEmpty { lines.append("Components: " + components.joined(separator: ", ")) }
        return .ok(lines.joined(separator: "\n"))
    }

    static func colimaConfig(profile: String) -> Outcome {
        let path = Paths.config(profile)
        guard FileManager.default.fileExists(atPath: path) else { return .skipped("the profile has no colima.yaml") }
        guard let data = FileManager.default.contents(atPath: path) else {
            return .failed("colima.yaml cannot be read")
        }
        let lines = ColimaConfigSummary.lines(of: String(decoding: data, as: UTF8.self))
        return .ok(
            (lines + ["Keys that are not listed use the defaults of Colima. Values of other keys are not included."])
                .joined(separator: "\n"))
    }

    // MARK: - Logs

    static func appLog() async -> Outcome {
        let cap = DiagnosticsPart.appLog.cap!
        let r = await Shell.run(
            ["/usr/bin/log", "show", "--style", "compact", "--info", "--last", "24h", "--predicate", logPredicate],
            timeout: DiagnosticsPart.appLog.timeout ?? 10, includeStderr: true)
        guard r.ok else { return .failed(failure(r)) }
        return .ok(DiagnosticsBundle.tail(r.out, lines: cap.lines, bytes: cap.bytes))
    }

    /// The end of a file. It seeks to the end and reads `bytes` bytes at most.
    static func tail(path: String, lines: Int, bytes: Int) -> Outcome {
        guard FileManager.default.fileExists(atPath: path) else { return .skipped("the file does not exist") }
        guard let handle = FileHandle(forReadingAtPath: path) else { return .failed("the file cannot be read") }
        defer { try? handle.close() }
        do {
            let size = Int(try handle.seekToEnd())
            let start = max(0, size - bytes)
            try handle.seek(toOffset: UInt64(start))
            var text = String(decoding: try handle.read(upToCount: bytes) ?? Data(), as: UTF8.self)
            var cut = false
            if start > 0 {
                // The read can begin inside a line or a character.
                cut = true
                while text.first == "\u{FFFD}" { text.removeFirst() }
                if let nl = text.firstIndex(of: "\n") { text = String(text[text.index(after: nl)...]) }
            }
            let out = DiagnosticsBundle.tail(text, lines: lines, bytes: bytes)
            let note = DiagnosticsBundle.cutNote(lines: lines, bytes: bytes)
            return .ok(cut && !out.hasPrefix("[older lines cut") ? note + "\n" + out : out)
        } catch {
            return .failed("the file cannot be read")
        }
    }

    static func ctlLog() -> Outcome {
        let cap = DiagnosticsPart.ctlLog.cap!
        return tail(path: Paths.ctlLog, lines: cap.lines, bytes: cap.bytes)
    }

    static func limaLog(profile: String) -> Outcome {
        let cap = DiagnosticsPart.limaLog.cap!
        return tail(path: Paths.limaHostAgentLog(profile), lines: cap.lines, bytes: cap.bytes)
    }

    /// The crash reports of ColimaBar of the last 30 days: the names, and the
    /// digest of the newest two.
    static func crashReports(now: Date = Date()) -> Outcome {
        crashReports(in: [Paths.crashReportsDir, Paths.crashReportsDir + "/Retired"], now: now)
    }

    /// The reports in the folders. A missing folder is normal (no crash,
    /// or no retired reports). A folder that cannot be read is a failure: it
    /// must not read as "no crashes".
    static func crashReports(in dirs: [String], now: Date) -> Outcome {
        let fm = FileManager.default
        var found: [String: String] = [:]  // name -> folder
        for dir in dirs {
            do {
                for n in try fm.contentsOfDirectory(atPath: dir) where n.hasPrefix("ColimaBar-") && found[n] == nil {
                    found[n] = dir
                }
            } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
                continue
            } catch {
                return .failed("the crash report folder cannot be read: \(error.localizedDescription)")
            }
        }
        let picked = CrashReportDigest.pick(names: Array(found.keys), now: now)
        guard !picked.isEmpty else { return .ok("No crash reports of ColimaBar in the last 30 days.") }
        var lines = ["Crash reports of the last 30 days (newest first):"] + picked.map { "  \($0)" }
        var problems: [String] = []
        for name in picked.prefix(2) {
            lines += ["", "-- \(name) --"]
            guard let dir = found[name] else { continue }
            do {
                let h = try FileHandle(forReadingFrom: URL(fileURLWithPath: "\(dir)/\(name)"))
                defer { try? h.close() }
                let data = try h.read(upToCount: 4 * 1024 * 1024) ?? Data()
                lines.append(
                    CrashReportDigest.reduce(String(decoding: data, as: UTF8.self))
                        ?? "not read: not a crash report of ColimaBar")
            } catch {
                lines.append("not read: \(error.localizedDescription)")
                problems.append("\(name) cannot be read")
            }
        }
        let text = lines.joined(separator: "\n")
        return problems.isEmpty ? .ok(text) : .partial(text, problems.joined(separator: "; "))
    }

    // MARK: - Names to hide

    /// The redactor for this Mac and this user, and whether it has all the
    /// names. The `scutil` calls have a 2 s time-out. `gethostname` does not
    /// block, unlike `ProcessInfo.hostName`.
    static func redactor() async -> (Redactor, Bool) {
        async let computer = Shell.run(["scutil", "--get", "ComputerName"], timeout: 2)
        async let local = Shell.run(["scutil", "--get", "LocalHostName"], timeout: 2)
        var buf = [CChar](repeating: 0, count: 256)
        let host = gethostname(&buf, buf.count) == 0 ? text(buf) : ""
        var macNames = [host, host.split(separator: ".").first.map(String.init) ?? ""]
        var complete = !host.isEmpty
        for r in [await computer, await local] {
            if r.ok {
                macNames.append(r.out.trimmingCharacters(in: .whitespacesAndNewlines))
            } else {
                complete = false
            }
        }
        let redactor = Redactor(
            home: Paths.home, userNames: [NSUserName(), NSFullUserName()], macNames: macNames.filter { !$0.isEmpty })
        return (redactor, complete)
    }

    // MARK: - The file

    /// Writes the text to `url` with the mode 0600 from the first byte. A file
    /// that others can read never exists, not even for a moment.
    ///
    /// With `replace`, the text goes to a new private temporary file beside
    /// `url`, then `rename` puts it over `url`: an old file or link at `url`
    /// is replaced. The save panel confirmed that. Without `replace`, `url`
    /// must be new: `O_EXCL` and `O_NOFOLLOW` make the system refuse a file
    /// or a link that is there (`CLIDiagnosticsPath.Failure.exists`). A write
    /// error keeps its reason and leaves no file.
    static func write(_ text: String, to url: URL, replace: Bool = true) throws {
        let data = Data(text.utf8)
        guard replace else {
            do {
                try createPrivateFile(at: url.path, data: data)
            } catch let error as POSIXError where error.code == .EEXIST {
                throw CLIDiagnosticsPath.Failure.exists(url.path)
            }
            return
        }
        let temp = "\(url.path).\(getpid()).tmp"
        unlink(temp)
        try createPrivateFile(at: temp, data: data)
        if rename(temp, url.path) != 0 {
            let code = errno
            unlink(temp)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
    }

    /// Makes a new file with the mode 0600 and writes `data`. It never opens
    /// an existing file or a link. A failure removes the file again.
    private static func createPrivateFile(at path: String, data: Data) throws {
        let fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var written = 0
        var failure: Int32 = 0
        data.withUnsafeBytes { raw in
            while written < data.count {
                let n = Darwin.write(fd, raw.baseAddress! + written, data.count - written)
                if n < 0 {
                    if errno == EINTR { continue }
                    failure = errno
                    return
                }
                written += n
            }
        }
        if close(fd) != 0, failure == 0 { failure = errno }
        if failure != 0 {
            unlink(path)
            throw POSIXError(POSIXErrorCode(rawValue: failure) ?? .EIO)
        }
    }
}
