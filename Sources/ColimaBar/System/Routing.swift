import Foundation
import os

/// Points every way a docker client finds its daemon at ColimaBar's stable
/// socket (Paths.proxySocket), so `docker run` from a terminal, an IDE test
/// runner or testcontainers all go through the auto-start proxy.
///
/// When ColimaBar isn't running, the stable path is a symlink to Colima's
/// socket. Colima switches the docker context on start and deletes it on
/// stop, so ColimaBar moves the context back (`restoreContext`).
@MainActor
enum Routing {
    private static let log = Logger(category: "routing")
    nonisolated static let contextName = "colimabar"
    static var stableHost: String { "unix://\(Paths.proxySocket)" }

    struct Status: Equatable {
        var context = false  // docker context "colimabar" is current
        var launchd = false  // GUI apps get DOCKER_HOST
        var testcontainers = false  // ~/.testcontainers.properties docker.host
        var varRun = false  // /var/run/docker.sock -> stable socket
        /// The raw values behind the flags above, for Doctor.
        var launchdHost = ""  // launchctl getenv DOCKER_HOST
        var testcontainersHost: String?  // docker.host in ~/.testcontainers.properties
    }

    /// Applies the routes that need no admin rights. Leaves things alone if the
    /// user has deliberately chosen some other daemon (a remote context, a
    /// custom testcontainers docker.host).
    /// Returns what it changed.
    @discardableResult
    static func apply(selected: String) async -> Applied {
        var applied = Applied()
        let r = await ensureContext(selected: selected, launch: true)
        if r.ok || r.ours {
            applied.launchd = await applyLaunchd(contextIsOurs: r.ours)
        } else {
            log.error("left launchd DOCKER_HOST alone (the docker context check failed)")
        }
        applied.testcontainers = applyTestcontainers()
        return applied
    }

    /// The routes that `apply` changed.
    struct Applied: Equatable {
        var launchd = false
        var testcontainers = false
        var any: Bool { launchd || testcontainers }
    }

    /// True if `host` points to a daemon that is not ColimaBar's and not
    /// Colima's (a remote host, Docker Desktop). ColimaBar leaves such a route.
    /// An empty or missing host is not foreign.
    nonisolated static func isForeignHost(_ host: String?, stableHost: String, home: String) -> Bool {
        guard let host, !host.isEmpty, host != stableHost else { return false }
        // Only a local socket can be Colima's: a remote host with a Colima-like path stays foreign.
        guard host.hasPrefix("unix://") else { return true }
        return DoctorRules.hostKind(host, home: home) != .colima
    }

    /// Ryuk (testcontainers' reaper) bind-mounts the docker socket path into a
    /// container. Our host path isn't reachable inside the VM, the VM's own
    /// socket is.
    static let ryukSocket = "/var/run/docker.sock"

    /// Sets DOCKER_HOST for apps launched from the Dock or Finder (IDE test
    /// runners). Skipped when the user chose another daemon: a non-Colima
    /// context, or a DOCKER_HOST that points somewhere else.
    /// Returns true if it set DOCKER_HOST.
    @discardableResult
    private static func applyLaunchd(contextIsOurs: Bool) async -> Bool {
        let cur = await Shell.run(["launchctl", "getenv", "DOCKER_HOST"], timeout: 5).out
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let foreign = isForeignHost(cur, stableHost: stableHost, home: Paths.home)
        guard contextIsOurs, !foreign else {
            log.info("left launchd DOCKER_HOST alone (another daemon is in use)")
            return false
        }
        var changed = false
        if cur != stableHost {
            let set = await Shell.run(["launchctl", "setenv", "DOCKER_HOST", stableHost])
            if set.ok {
                changed = true
            } else {
                log.error("launchctl setenv DOCKER_HOST failed (exit \(set.status))")
            }
        }
        let ryuk = await Shell.run(["launchctl", "setenv", "TESTCONTAINERS_DOCKER_SOCKET_OVERRIDE", ryukSocket])
        if !ryuk.ok { log.error("launchctl setenv TESTCONTAINERS_DOCKER_SOCKET_OVERRIDE failed (exit \(ryuk.status))") }
        return changed
    }

    static func status() async -> Status {
        var s = Status()
        s.context = currentContext().map(isOurs) ?? false
        let env = await Shell.run(["launchctl", "getenv", "DOCKER_HOST"], timeout: 5)
        s.launchdHost = env.out.trimmingCharacters(in: .whitespacesAndNewlines)
        s.launchd = s.launchdHost == stableHost
        s.testcontainersHost = testcontainersHost()
        s.testcontainers = s.testcontainersHost == stableHost
        s.varRun =
            (try? FileManager.default.destinationOfSymbolicLink(atPath: "/var/run/docker.sock")) == Paths.proxySocket
        return s
    }

    /// The current docker context, read from the docker config file. Unlike
    /// `docker context show`, this works when the current context is missing
    /// (`colima stop` deletes it). "" means the default context. Nil means
    /// the file cannot be read or is not valid JSON.
    static func currentContext() -> String? {
        currentContext(path: Paths.dockerConfig(env: ProcessInfo.processInfo.environment, home: Paths.home))
    }

    /// Reads `currentContext` from a config file. A missing file, an empty
    /// file and a file without the key all mean the default context ("").
    nonisolated static func currentContext(path: String) -> String? {
        guard FileManager.default.fileExists(atPath: path) else { return "" }
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return currentContext(config: data)
    }

    /// The `currentContext` value of a docker config.json. "" if the key is
    /// absent or the data is empty. Nil if the data is not a JSON object.
    nonisolated static func currentContext(config: Data) -> String? {
        if config.allSatisfy({ $0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 }) { return "" }
        guard let obj = (try? JSONSerialization.jsonObject(with: config)) as? [String: Any] else { return nil }
        return obj["currentContext"] as? String ?? ""
    }

    /// The modification time of the docker config file, or nil if it is missing.
    /// A change means some tool switched the docker context.
    static func configStamp() -> Date? {
        configStamp(path: Paths.dockerConfig(env: ProcessInfo.processInfo.environment, home: Paths.home))
    }

    /// Follows a symlink: docker writes to the target of the link.
    nonisolated static func configStamp(path: String) -> Date? {
        let real = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        return (try? FileManager.default.attributesOfItem(atPath: real))?[.modificationDate] as? Date
    }

    nonisolated static func isOurs(_ context: String) -> Bool {
        context == contextName || context.hasPrefix(ProfileContexts.prefix)
    }

    /// The names of the contexts that exist, from `docker context ls` with
    /// `listFormat`. docker adds a row with an error for the current context
    /// when it is missing; that row is not a context.
    nonisolated static let listFormat = "{{.Name}}\t{{.Error}}"

    nonisolated static func existingContexts(listing: String) -> Set<String> {
        var names = Set<String>()
        for line in listing.split(separator: "\n") {
            let cols = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            if cols.count == 2, !cols[1].trimmingCharacters(in: .whitespaces).isEmpty { continue }
            if let name = cols.first, !name.isEmpty { names.insert(String(name)) }
        }
        return names
    }

    /// Moves the docker CLI back to a ColimaBar context after Colima changed
    /// it. Runs no docker process when nothing needs to change. When a
    /// ColimaBar context is current, it also sets the launchd and
    /// testcontainers routes, in case a first try missed them. Returns false
    /// when a step failed (the caller tries again later).
    static func restoreContext(selected: String) async -> Bool {
        guard let cur = currentContext() else {
            log.error("cannot read the docker config file")
            return false
        }
        var ours = isOurs(cur)
        var ok = true
        if !cur.isEmpty, cur != contextName, cur != "default" {
            let r = await ensureContext(selected: selected, launch: false)
            (ours, ok) = (r.ours, r.ok)
        }
        if ours {
            await applyLaunchd(contextIsOurs: true)
            applyTestcontainers()
        }
        return ok
    }

    /// The profile of a Colima docker context: "colima" is `default`,
    /// "colima-work" is `work`. Nil for any other name.
    nonisolated static func colimaProfile(_ context: String) -> String? {
        if context == "colima" { return "default" }
        let prefix = "colima-"
        guard context.hasPrefix(prefix), context.count > prefix.count else { return nil }
        return String(context.dropFirst(prefix.count))
    }

    /// The context to switch to, or nil to leave the current one. `existing`
    /// has only contexts that exist (see `existingContexts`).
    ///
    /// - `colimabar` stays.
    /// - The default context (empty or `default`) moves to `colimabar` only
    ///   at launch. Later, the user chose it.
    /// - A Colima context moves to the ColimaBar context of its profile
    ///   (`colimabar` for the selected profile, else `colimabar-PROFILE`).
    ///   If that context is missing, an existing Colima context stays and a
    ///   missing one moves to `colimabar`.
    /// - Any other context stays if it exists. If it is missing, it moves to
    ///   `colimabar`.
    nonisolated static func contextTarget(
        current: String, existing: Set<String>, selected: String, launch: Bool
    ) -> String? {
        if current == contextName { return nil }
        if current.isEmpty || current == "default" { return launch ? contextName : nil }
        if let profile = colimaProfile(current) {
            let target = profile == selected ? contextName : ProfileContexts.name(profile)
            if existing.contains(target) { return target }
        }
        return existing.contains(current) ? nil : contextName
    }

    /// Creates the "colimabar" context if `names` lacks it, and adds it to
    /// `names`. Returns false if the docker CLI failed.
    private static func createOwnContext(ifMissingFrom names: inout Set<String>) async -> Bool {
        guard !names.contains(contextName) else { return true }
        let made = await Shell.run(
            [
                "docker", "context", "create", contextName,
                "--description", "ColimaBar (auto-starts Colima)",
                "--docker", "host=\(stableHost)",
            ], timeout: 10)
        guard made.ok else {
            log.error("docker context create failed (exit \(made.status))")
            return false
        }
        names.insert(contextName)
        log.info("created docker context \(contextName, privacy: .public)")
        return true
    }

    /// Switches the docker CLI to the "colimabar" context and creates it if
    /// it is missing. The Doctor fix "Use colimabar" calls it. Unlike the
    /// automatic check, it also leaves a context that the user chose.
    static func useOwnContext() async -> Bool {
        let ls = await Shell.run(["docker", "context", "ls", "--format", listFormat], timeout: 10)
        guard ls.ok else {
            log.error("docker context ls failed (exit \(ls.status)) for Doctor")
            return false
        }
        var names = existingContexts(listing: ls.out)
        guard await createOwnContext(ifMissingFrom: &names) else { return false }
        let used = await Shell.run(["docker", "context", "use", contextName], timeout: 10)
        if used.ok {
            log.notice("switched the docker context to \(contextName, privacy: .public) (Doctor)")
        } else {
            log.error("docker context use \(contextName, privacy: .public) failed (exit \(used.status)) for Doctor")
        }
        return used.ok
    }

    /// Creates the "colimabar" context if it is missing and switches to the
    /// context that `contextTarget` gives. `ours`: a ColimaBar context is
    /// current afterwards. `ok`: no step failed.
    private static func ensureContext(selected: String, launch: Bool) async -> (ours: Bool, ok: Bool) {
        let ls = await Shell.run(["docker", "context", "ls", "--format", listFormat], timeout: 10)
        guard ls.ok else {
            log.error("docker context ls failed (exit \(ls.status))")
            return (false, false)
        }
        guard let cur = currentContext() else {
            log.error("cannot read the docker config file")
            return (false, false)
        }
        var names = existingContexts(listing: ls.out)
        var ok = await createOwnContext(ifMissingFrom: &names)
        var now = cur
        if let target = contextTarget(current: cur, existing: names, selected: selected, launch: launch),
            names.contains(target)
        {
            let used = await Shell.run(["docker", "context", "use", target], timeout: 10)
            if used.ok {
                let cause = launch ? "ColimaBar started" : "auto-start is on"
                log.notice(
                    "switched docker context \(cur.isEmpty ? "default" : cur, privacy: .public) to \(target, privacy: .public) (\(cause, privacy: .public))"
                )
                now = target
            } else {
                ok = false
                log.error("docker context use \(target, privacy: .public) failed (exit \(used.status))")
            }
        }
        return (isOurs(now), ok)
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
    /// Returns true if it wrote the file. It never rewrites a file that it
    /// cannot read as UTF-8 text.
    @discardableResult
    static func applyTestcontainers(path: String = Paths.testcontainersProps) -> Bool {
        let existing: String
        switch DockerConfigFile.read(path: path) {
        case .missing:
            existing = ""
        case .unreadable:
            log.error("cannot read \(path, privacy: .public); left it alone")
            return false
        case .data(let data):
            guard let text = String(data: data, encoding: .utf8) else {
                log.error("\(path, privacy: .public) is not UTF-8 text; left it alone")
                return false
            }
            existing = text
        }
        let current = existing.split(separator: "\n").lazy.compactMap { dockerHostValue($0) }.first
        if isForeignHost(current, stableHost: stableHost, home: Paths.home) { return false }
        guard current != stableHost else { return false }
        var lines =
            existing
            .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            .filter { dockerHostValue($0) == nil }
        while lines.last == "" { lines.removeLast() }
        lines.append("docker.host=\(stableHost)")
        // Write through a symlink (dotfile managers) and keep the file's mode.
        let content = Data((lines.joined(separator: "\n") + "\n").utf8)
        do {
            let target = try SymlinkWrite.write(content, to: path)
            log.info("set testcontainers docker.host in \(target, privacy: .public)")
            return true
        } catch {
            log.error(
                "couldn't write \(path, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            return false
        }
    }

    // MARK: - /var/run/docker.sock (needs admin once)

    /// Symlinks /var/run/docker.sock to the stable socket for tools that only
    /// look there. Prompts for an admin password.
    /// Refuses to replace a real socket there (Docker Desktop's).
    static func linkVarRun() async -> Bool {
        let varRun = "/var/run/docker.sock"
        if let type = (try? FileManager.default.attributesOfItem(atPath: varRun))?[.type] as? FileAttributeType,
            type != .typeSymbolicLink
        {
            log.error("\(varRun, privacy: .public) is a real file or socket; not replacing it")
            return false
        }
        // Pass the path through AppleScript's `quoted form of`, so no
        // character in it can change the root shell command.
        let asPath = Paths.proxySocket.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script =
            "do shell script \"/bin/ln -sfn \" & quoted form of \"\(asPath)\" & \" \(varRun)\" with administrator privileges"
        return await Shell.run(["osascript", "-e", script], timeout: 120).ok
    }
}
