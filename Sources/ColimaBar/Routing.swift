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
        await ensureContext()
        _ = await Shell.run(["launchctl", "setenv", "DOCKER_HOST", stableHost])
        applyTestcontainers()
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
    /// current context is a Colima one (or the env-based default).
    private static func ensureContext() async {
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
        if cur == "default" || cur.hasPrefix("colima") {
            _ = await Shell.run(["docker", "context", "use", contextName], timeout: 10)
        }
    }

    // MARK: - testcontainers

    static func testcontainersHost() -> String? {
        guard let text = try? String(contentsOfFile: Paths.testcontainersProps, encoding: .utf8) else { return nil }
        return text.split(separator: "\n").lazy
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { $0.hasPrefix("docker.host=") }
            .map { String($0.dropFirst("docker.host=".count)) }
    }

    /// Sets docker.host unless the user already points it somewhere that
    /// isn't Colima.
    private static func applyTestcontainers() {
        let current = testcontainersHost()
        if let current, current != stableHost, !current.contains("/colima/") { return }
        guard current != stableHost else { return }
        var lines = ((try? String(contentsOfFile: Paths.testcontainersProps, encoding: .utf8)) ?? "")
            .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("docker.host=") }
        while lines.last == "" { lines.removeLast() }
        lines.append("docker.host=\(stableHost)")
        try? (lines.joined(separator: "\n") + "\n").write(toFile: Paths.testcontainersProps, atomically: true, encoding: .utf8)
        log.info("set testcontainers docker.host")
    }

    // MARK: - /var/run/docker.sock (needs admin once)

    /// Symlinks /var/run/docker.sock to the stable socket for tools that only
    /// look there. Prompts for an admin password.
    static func linkVarRun() async -> Bool {
        let cmd = "ln -sfn '\(Paths.proxySocket)' /var/run/docker.sock"
        let r = await Shell.run(["osascript", "-e",
                                 "do shell script \"\(cmd)\" with administrator privileges"], timeout: 120)
        return r.ok
    }
}

/// Launch at login through a LaunchAgent with KeepAlive, so a crash relaunches
/// ColimaBar immediately instead of leaving the proxy socket dead. A normal
/// Quit (exit 0) is respected.
@MainActor
enum LoginItem {
    static let agent = SMAppService.agent(plistName: "com.imohitkr.ColimaBar.agent.plist")

    static var isEnabled: Bool { agent.status == .enabled }
    static var needsApproval: Bool { agent.status == .requiresApproval }

    static func set(_ on: Bool) throws {
        if on {
            try agent.register()
            if agent.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
        } else {
            try agent.unregister()
        }
    }

    /// Moves older installs from the plain login item to the KeepAlive agent.
    static func migrate() {
        if SMAppService.mainApp.status == .enabled {
            try? SMAppService.mainApp.unregister()
            try? agent.register()
        }
    }
}
