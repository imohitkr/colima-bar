import Foundation
import os
import ServiceManagement

/// Points every way a docker client finds its daemon at ColimaBar's stable
/// socket (Paths.proxySocket), so `docker run` from a terminal, an IDE test
/// runner or testcontainers all go through the auto-start proxy.
///
/// The routes are set once and never need switching back: when ColimaBar
/// isn't running, the stable path is a symlink to Colima's socket.
@MainActor
enum Routing {
    private static let log = Logger(subsystem: "com.imohitkr.ColimaBar", category: "routing")
    static let contextName = "colimabar"
    static var stableHost: String { "unix://\(Paths.proxySocket)" }

    struct Status: Equatable {
        var context = false          // docker context "colimabar" is current
        var launchd = false          // GUI apps get DOCKER_HOST
        var testcontainers = false   // ~/.testcontainers.properties docker.host
        var varRun = false           // /var/run/docker.sock -> stable socket
    }

    /// Applies the routes that need no admin rights. Leaves things alone if the
    /// user has deliberately chosen some other daemon (a remote context, a
    /// custom testcontainers docker.host).
    static func apply() async {
        let ours = await ensureContext()
        await applyLaunchd(contextIsOurs: ours)
        applyTestcontainers()
    }

    /// Ryuk (testcontainers' reaper) bind-mounts the docker socket path into a
    /// container. Our host path isn't reachable inside the VM, the VM's own
    /// socket is.
    static let ryukSocket = "/var/run/docker.sock"

    /// Sets DOCKER_HOST for apps launched from the Dock or Finder (IDE test
    /// runners). Skipped when the user chose another daemon: a non-Colima
    /// context, or a DOCKER_HOST that points somewhere else.
    private static func applyLaunchd(contextIsOurs: Bool) async {
        let cur = await Shell.run(["launchctl", "getenv", "DOCKER_HOST"], timeout: 5).out
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let foreign = !cur.isEmpty && cur != stableHost && !cur.contains("/colima/")
        guard contextIsOurs, !foreign else {
            log.info("left launchd DOCKER_HOST alone (another daemon is in use)")
            return
        }
        if cur != stableHost {
            _ = await Shell.run(["launchctl", "setenv", "DOCKER_HOST", stableHost])
        }
        _ = await Shell.run(["launchctl", "setenv", "TESTCONTAINERS_DOCKER_SOCKET_OVERRIDE", ryukSocket])
    }

    static func status() async -> Status {
        var s = Status()
        let cur = await Shell.run(["docker", "context", "show"], timeout: 5)
        s.context = cur.out.trimmingCharacters(in: .whitespacesAndNewlines) == contextName
        let env = await Shell.run(["launchctl", "getenv", "DOCKER_HOST"], timeout: 5)
        s.launchd = env.out.trimmingCharacters(in: .whitespacesAndNewlines) == stableHost
        s.testcontainers = testcontainersHost() == stableHost
        s.varRun = (try? FileManager.default.destinationOfSymbolicLink(atPath: "/var/run/docker.sock")) == Paths.proxySocket
        return s
    }

    /// Creates the "colimabar" context and switches to it, but only when the
    /// current context is a Colima one (or the env-based default). Returns
    /// true when "colimabar" is the current context afterwards.
    private static func ensureContext() async -> Bool {
        let ls = await Shell.run(["docker", "context", "ls", "--format", "{{.Name}}"], timeout: 10)
        let names = Set(ls.out.split(separator: "\n").map(String.init))
        if !names.contains(contextName) {
            _ = await Shell.run(["docker", "context", "create", contextName,
                                 "--description", "ColimaBar (auto-starts Colima)",
                                 "--docker", "host=\(stableHost)"], timeout: 10)
            log.info("created docker context \(contextName, privacy: .public)")
        }
        let cur = await Shell.run(["docker", "context", "show"], timeout: 5).out
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if cur == contextName { return true }
        if cur == "default" || cur.hasPrefix("colima") {
            return await Shell.run(["docker", "context", "use", contextName], timeout: 10).ok
        }
        return false
    }

    // MARK: - testcontainers

    static func testcontainersHost() -> String? {
        guard let text = try? String(contentsOfFile: Paths.testcontainersProps, encoding: .utf8) else { return nil }
        return text.split(separator: "\n").lazy.compactMap { dockerHostValue($0) }.first
    }

    /// The value of a `docker.host` line in a Java properties file, or nil.
    /// Java allows spaces around the key. The separator is `=`, `:` or only
    /// whitespace (`docker.host tcp://remote:2375`), so this matches
    /// `^\s*docker\.host(\s*[=:]|\s)\s*(.*)$`. A `#` comment line and
    /// another key (`docker.hostname`) don't match.
    nonisolated static func dockerHostValue<S: StringProtocol>(_ line: S) -> String? {
        let blank: (Character) -> Bool = { $0 == " " || $0 == "\t" || $0 == "\u{0C}" }
        var rest = line.drop(while: blank)
        guard rest.hasPrefix("docker.host") else { return nil }
        rest = rest.dropFirst("docker.host".count)
        // The key ends at whitespace, "=" or ":".
        guard let end = rest.first, blank(end) || end == "=" || end == ":" else { return nil }
        rest = rest.drop(while: blank)
        if let sep = rest.first, sep == "=" || sep == ":" { rest = rest.dropFirst() }
        return rest.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Sets docker.host unless the user already points it somewhere that
    /// isn't Colima.
    private static func applyTestcontainers() {
        let current = testcontainersHost()
        if let current, current != stableHost, !current.contains("/colima/") { return }
        guard current != stableHost else { return }
        var lines = ((try? String(contentsOfFile: Paths.testcontainersProps, encoding: .utf8)) ?? "")
            .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            .filter { dockerHostValue($0) == nil }
        while lines.last == "" { lines.removeLast() }
        lines.append("docker.host=\(stableHost)")
        // Write through a symlink (dotfile managers) and keep the file's mode;
        // an atomic write would replace the link with a plain file.
        let fm = FileManager.default
        let target = (try? fm.destinationOfSymbolicLink(atPath: Paths.testcontainersProps))
            .map { $0.hasPrefix("/") ? $0 : ((Paths.testcontainersProps as NSString).deletingLastPathComponent as NSString)
                .appendingPathComponent($0) } ?? Paths.testcontainersProps
        let mode = (try? fm.attributesOfItem(atPath: target))?[.posixPermissions]
        do {
            try (lines.joined(separator: "\n") + "\n").write(toFile: target, atomically: true, encoding: .utf8)
            if let mode { try? fm.setAttributes([.posixPermissions: mode], ofItemAtPath: target) }
            log.info("set testcontainers docker.host")
        } catch {
            log.error("couldn't write \(target, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - /var/run/docker.sock (needs admin once)

    /// Symlinks /var/run/docker.sock to the stable socket for tools that only
    /// look there. Prompts for an admin password.
    /// Refuses to replace a real socket there (Docker Desktop's).
    static func linkVarRun() async -> Bool {
        let varRun = "/var/run/docker.sock"
        if let type = (try? FileManager.default.attributesOfItem(atPath: varRun))?[.type] as? FileAttributeType,
           type != .typeSymbolicLink {
            log.error("\(varRun, privacy: .public) is a real file or socket; not replacing it")
            return false
        }
        // Pass the path through AppleScript's `quoted form of`, so no
        // character in it can change the root shell command.
        let asPath = Paths.proxySocket.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = "do shell script \"/bin/ln -sfn \" & quoted form of \"\(asPath)\" & \" \(varRun)\" with administrator privileges"
        return await Shell.run(["osascript", "-e", script], timeout: 120).ok
    }
}

/// Launch at login through a LaunchAgent with KeepAlive, so a crash relaunches
/// ColimaBar immediately instead of leaving the proxy socket dead. A normal
/// Quit (exit 0) is respected.
///
/// This is a plain plist in ~/Library/LaunchAgents, not SMAppService: launchd
/// pins an SMAppService agent to the code signature it was registered with,
/// and an ad-hoc signed app gets a new signature with every build, so after
/// an update launchd refused to start it (EX_CONFIG, launch constraint
/// violation) and ColimaBar didn't start at login.
@MainActor
enum LoginItem {
    nonisolated static let label = "com.imohitkr.ColimaBar.login"
    /// Label of the SMAppService agent used up to v0.2.0 (see migrate()).
    nonisolated static let legacyLabel = "com.imohitkr.ColimaBar.agent"
    nonisolated static var plistPath: String { "\(Paths.home)/Library/LaunchAgents/\(label).plist" }
    nonisolated private static var domain: String { "gui/\(getuid())" }
    nonisolated private static let log = Logger(subsystem: "com.imohitkr.ColimaBar", category: "login")
    /// Runs launchctl off the main thread, one call after another, so
    /// quick on/off toggles reach launchd in order.
    nonisolated private static let queue = DispatchQueue(label: "com.imohitkr.ColimaBar.login")

    static var isEnabled: Bool { FileManager.default.fileExists(atPath: plistPath) }

    /// True when the agent exists but was turned off in System Settings >
    /// General > Login Items, so launchd won't run it.
    static var needsApproval: Bool { isEnabled && disabledInSettings() }

    /// Runs launchctl: call it off the main thread from UI code.
    nonisolated static func disabledInSettings() -> Bool {
        let out = launchctl(["print-disabled", "gui/\(getuid())"]).out
        return out.contains("\"\(label)\" => disabled") || out.contains("\"\(label)\" => true")
    }

    /// The job is loaded in launchd (running or not). Runs launchctl.
    nonisolated static var isLoaded: Bool { launchctl(["print", "\(domain)/\(label)"]).ok }

    /// On: writes the plist and loads the job, which starts the agent
    /// (RunAtLoad). The agent then takes over from this copy, the same way as
    /// at launch: it quits this copy and waits for it to exit. If launchd
    /// refuses the job, this copy keeps running unsupervised.
    /// The job can still be loaded when the agent turned launch at login off
    /// and then quit. A copy started by hand reloads it, so launchd reads the
    /// new plist and starts the agent. The agent itself only writes the plist:
    /// its job is still loaded and keeps it alive.
    /// Off: removes the plist, so it won't start at the next login. When this
    /// copy *is* the agent, the job stays loaded until logout: unloading it
    /// would kill this process (and the proxy) on the spot.
    /// The plist changes before this returns, so isEnabled (and the UI that
    /// reads it) is correct at once. launchctl runs later on a background
    /// queue: a bootstrap can retry for about 2 s, and the menu or toggle
    /// must not hang meanwhile. bootstrap() logs a failure.
    static func set(_ on: Bool) throws {
        if on {
            try writePlist()
        } else {
            try? FileManager.default.removeItem(atPath: plistPath)
        }
        guard !AppDelegate.isLaunchAgent else { return }
        queue.async {
            if on {
                if isLoaded { launchctl(["bootout", "\(domain)/\(label)"]) }
                bootstrap()
            } else {
                launchctl(["bootout", "\(domain)/\(label)"])
            }
        }
    }

    /// Rewrites the plist if the app moved or the plist is outdated, so it
    /// always starts the installed binary.
    /// Only an installed copy (in /Applications or ~/Applications) takes the
    /// plist over, or any copy when the plist's binary is gone. A copy run
    /// from Downloads or a build folder must not repoint it.
    /// If only other keys differ (an older version wrote the plist), it
    /// rewrites the file but does not reload the job. launchd reads the new
    /// keys at the next login. The agent also calls this: a reload would
    /// kill it.
    static func refreshIfNeeded() {
        guard isEnabled, let exe = Bundle.main.executablePath,
              let data = FileManager.default.contents(atPath: plistPath),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return }
        let current = plist["Program"] as? String ?? ""
        guard current != exe else {
            if plistIsOutdated(plist, exe: exe) {
                log.notice("login agent plist is outdated; rewriting it")
                try? writePlist()
            }
            return
        }
        guard !AppDelegate.isLaunchAgent else { return }
        guard isInstalled(exe) || !FileManager.default.isExecutableFile(atPath: current) else { return }
        log.notice("login agent points at another binary; updating it")
        try? writePlist()
        launchctl(["bootout", "\(domain)/\(label)"])
        bootstrap()
    }

    /// True for a path inside /Applications or ~/Applications that macOS
    /// did not translocate (a copy run from a DMG or Downloads is not).
    nonisolated static func isInstalled(_ path: String) -> Bool {
        (path.hasPrefix("/Applications/") || path.hasPrefix("\(Paths.home)/Applications/"))
            && !path.contains("/AppTranslocation/")
    }

    /// Loads the job. Right after a bootout, launchd can still be removing
    /// the old job and refuse the bootstrap for a moment, so retry briefly.
    @discardableResult
    nonisolated private static func bootstrap() -> Bool {
        var r = launchctl(["bootstrap", domain, plistPath])
        var tries = 0
        while !r.ok, !isLoaded, tries < 10 {
            usleep(200_000)
            r = launchctl(["bootstrap", domain, plistPath])
            tries += 1
        }
        if !r.ok, !isLoaded { log.error("launchctl bootstrap failed: \(r.out, privacy: .public)") }
        return r.ok || isLoaded
    }

    /// Asks launchd to start the agent now, loading it first if needed.
    /// True if launchctl accepted it.
    static func kickstart() -> Bool {
        if launchctl(["kickstart", "\(domain)/\(label)"]).ok { return true }
        return launchctl(["bootstrap", domain, plistPath]).ok
    }

    /// Moves older installs (SMAppService agent or plain login item) to the
    /// plist agent.
    /// The bundle still ships the old agent plist only so SMAppService can
    /// find, and unregister, that registration.
    /// Runs once: if unregistering fails, it must not re-enable launch at
    /// login on every start after the user turned it off.
    static func migrate() {
        guard !UserDefaults.standard.bool(forKey: "didMigrateLoginItem") else { return }
        UserDefaults.standard.set(true, forKey: "didMigrateLoginItem")
        let old = SMAppService.agent(plistName: "\(legacyLabel).plist")
        let hadOld = old.status == .enabled || old.status == .requiresApproval
            || SMAppService.mainApp.status == .enabled
        guard hadOld else { return }
        try? old.unregister()
        try? SMAppService.mainApp.unregister()
        log.notice("migrating launch at login to ~/Library/LaunchAgents")
        if !isEnabled { try? set(true) }
    }

    /// The LaunchAgent plist for the binary at `exe`.
    /// SoftResourceLimits raises the open-file limit from launchd's 256
    /// (see FileLimit). The app also raises it itself at launch.
    nonisolated static func plistContents(exe: String) -> [String: Any] {
        [
            "Label": label,
            "Program": exe,
            "RunAtLoad": true,
            "KeepAlive": ["SuccessfulExit": false],
            "ProcessType": "Interactive",
            "LimitLoadToSessionType": "Aqua",
            "SoftResourceLimits": ["NumberOfFiles": Int(FileLimit.wanted)],
        ]
    }

    /// True when the plist on disk differs from the one this version writes.
    nonisolated static func plistIsOutdated(_ plist: [String: Any], exe: String) -> Bool {
        !NSDictionary(dictionary: plist).isEqual(to: plistContents(exe: exe))
    }

    private static func writePlist() throws {
        guard let exe = Bundle.main.executablePath else { throw CocoaError(.fileNoSuchFile) }
        let data = try PropertyListSerialization.data(fromPropertyList: plistContents(exe: exe), format: .xml, options: 0)
        try FileManager.default.createDirectory(atPath: (plistPath as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        try data.write(to: URL(fileURLWithPath: plistPath), options: .atomic)
    }

    @discardableResult
    nonisolated private static func launchctl(_ args: [String]) -> Shell.Result {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        guard (try? p.run()) != nil else { return Shell.Result(status: -1, out: "") }
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        return Shell.Result(status: p.terminationStatus, out: out)
    }
}
