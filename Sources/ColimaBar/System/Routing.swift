import Foundation
import ServiceManagement
import os

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
        var context = false  // docker context "colimabar" is current
        var launchd = false  // GUI apps get DOCKER_HOST
        var testcontainers = false  // ~/.testcontainers.properties docker.host
        var varRun = false  // /var/run/docker.sock -> stable socket
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
        s.varRun =
            (try? FileManager.default.destinationOfSymbolicLink(atPath: "/var/run/docker.sock")) == Paths.proxySocket
        return s
    }

    /// Creates the "colimabar" context and switches to it, but only when the
    /// current context is a Colima one (or the env-based default). Returns
    /// true when "colimabar" is the current context afterwards.
    private static func ensureContext() async -> Bool {
        let ls = await Shell.run(["docker", "context", "ls", "--format", "{{.Name}}"], timeout: 10)
        let names = Set(ls.out.split(separator: "\n").map(String.init))
        if !names.contains(contextName) {
            _ = await Shell.run(
                [
                    "docker", "context", "create", contextName,
                    "--description", "ColimaBar (auto-starts Colima)",
                    "--docker", "host=\(stableHost)",
                ], timeout: 10)
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
        let target =
            (try? fm.destinationOfSymbolicLink(atPath: Paths.testcontainersProps))
            .map {
                $0.hasPrefix("/")
                    ? $0
                    : ((Paths.testcontainersProps as NSString).deletingLastPathComponent as NSString)
                        .appendingPathComponent($0)
            } ?? Paths.testcontainersProps
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
