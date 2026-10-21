import Foundation
import Testing

@testable import ColimaBar

/// Tests the helper functions of scripts/uninstall.sh. The tests source only
/// the block between "# BEGIN helpers" and "# END helpers", which defines
/// functions and runs nothing. The full script quits ColimaBar, so it never
/// runs in a test.
@Suite struct UninstallScriptTests {
    private func script() throws -> String {
        try String(contentsOf: ScriptSandbox.repo.appendingPathComponent("scripts/uninstall.sh"), encoding: .utf8)
    }

    /// Writes the helper block to the sandbox and returns its path.
    private func helpers(_ sb: ScriptSandbox) throws -> String {
        let text = try script()
        let start = try #require(text.range(of: "# BEGIN helpers"))
        let end = try #require(text.range(of: "# END helpers"))
        let path = sb.root + "/helpers.sh"
        try String(text[start.lowerBound..<end.upperBound]).write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    private func call(_ sb: ScriptSandbox, _ code: String) async throws -> (status: Int32, out: String) {
        let h = try helpers(sb)
        return try await sb.bash([
            "-c", "set -uo pipefail; PROFILES_DIR=\"$HOME/.cache/colima-bar/profiles\"; . '\(h)'; \(code)",
        ])
    }

    @Test func theHelperBlockOnlyDefinesFunctions() async throws {
        let sb = try ScriptSandbox()
        let r = try await call(sb, "true")
        #expect(r.status == 0 && r.out.isEmpty)
        #expect(sb.calls.isEmpty)  // sourcing ran no tool
    }

    @Test func contextsAreTheColimabarProfileContextsOfColimaBar() async throws {
        // The same rule as ProfileContexts.isOurs: the description starts with "ColimaBar".
        let sb = try ScriptSandbox()
        let rows = [
            "colimabar\tColimaBar auto-start proxy",
            "colimabar-work\tColimaBar profile work",
            "colimabar-a.b\tColimaBar",
            "colimabar-mine\tmy own context",
            "colimabar-empty\t",
            "colimabar-lower\tcolimabar profile",
            "default\tCurrent DOCKER_HOST based configuration",
            "colima-work\tcolima [profile=work]",
            "mycolimabar-x\tColimaBar",
            "colimabar-\tColimaBar",
        ]
        try sb.stub(
            "docker",
            """
            printf 'docker %s\\n' "$*" >> "\(sb.log)"
            printf '\(rows.joined(separator: "\\n"))\\n'
            """)
        let r = try await call(sb, "colimabar_contexts")
        #expect(r.out.split(separator: "\n") == ["colimabar-work", "colimabar-a.b"])
        #expect(sb.calls == ["docker context ls --format {{.Name}}\\t{{.Description}}"])
        // No docker CLI: no contexts, no error.
        try FileManager.default.removeItem(atPath: sb.bin + "/docker")
        #expect(try await call(sb, "colimabar_contexts").out.isEmpty)
    }

    @Test func profileSocketsAreFoundAndLinkedToTheirProfiles() async throws {
        let sb = try ScriptSandbox()
        let dir = sb.home + "/.cache/colima-bar/profiles"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: dir + "/work.sock", contents: nil)
        symlink("/nonexistent", dir + "/b.sock")
        FileManager.default.createFile(atPath: dir + "/x.sock.tmp", contents: nil)
        FileManager.default.createFile(atPath: dir + "/notes.txt", contents: nil)
        let names = try await call(sb, "profile_socket_names").out.split(separator: "\n")
        #expect(names == ["b", "work"])

        try FileManager.default.removeItem(atPath: sb.home + "/.cache/colima-bar")
        try FileManager.default.createDirectory(atPath: sb.home + "/.config/colima", withIntermediateDirectories: true)
        #expect(try await call(sb, "link_profile_sockets work b").status == 0)
        let fm = FileManager.default
        #expect(
            try fm.destinationOfSymbolicLink(atPath: dir + "/work.sock") == sb.home + "/.config/colima/work/docker.sock"
        )
        #expect(try fm.destinationOfSymbolicLink(atPath: dir + "/b.sock") == sb.home + "/.config/colima/b/docker.sock")
        #expect(try await call(sb, "link_profile_sockets").status == 0)  // no profiles: nothing to do
    }

    @Test func colimaDirUsesTheRulesOfTheApp() async throws {
        // The same cases as PathsTests.colimaDirUsesTheFirstRuleThatApplies.
        let sb = try ScriptSandbox()
        let fm = FileManager.default
        func dir(_ env: String = "") async throws -> String {
            try await call(sb, "\(env) colima_dir").out.trimmingCharacters(in: .newlines)
        }
        let xdg = "XDG_CONFIG_HOME='\(sb.home)/xdg'"
        // 5. Nothing exists: ~/.colima. 4. XDG_CONFIG_HOME is set: its colima folder.
        #expect(try await dir() == sb.home + "/.colima")
        #expect(try await dir(xdg) == sb.home + "/xdg/colima")
        // 3. ~/.config/colima exists.
        try fm.createDirectory(atPath: sb.home + "/.config/colima", withIntermediateDirectories: true)
        #expect(try await dir(xdg) == sb.home + "/.config/colima")
        // 2. ~/.colima exists.
        try fm.createDirectory(atPath: sb.home + "/.colima", withIntermediateDirectories: true)
        #expect(try await dir(xdg) == sb.home + "/.colima")
        // 1. COLIMA_HOME exists. A missing one is ignored.
        try fm.createDirectory(atPath: sb.home + "/custom", withIntermediateDirectories: true)
        #expect(try await dir("COLIMA_HOME='\(sb.home)/custom'") == sb.home + "/custom")
        #expect(try await dir("COLIMA_HOME='\(sb.home)/missing'") == sb.home + "/.colima")
    }

    @Test(arguments: [
        ("colimabar-work", ["colima-work"], "colima-work"),
        ("colimabar-default", ["colima"], "colima"),
        ("colimabar", ["colima"], "colima"),
        // Colima's context of the profile is gone: colima, then default.
        ("colimabar-work", ["colima"], "colima"),
        ("colimabar-work", [], "default"),
    ])
    func leavingAContextPrefersTheContextOfColimaForItsProfile(
        current: String, existing: [String], expected: String
    ) async throws {
        let sb = try ScriptSandbox()
        // A stub docker that knows only the `existing` contexts and default.
        let known = (existing + ["default"]).joined(separator: " ")
        try sb.stub(
            "docker",
            """
            printf 'docker %s\\n' "$*" >> "\(sb.log)"
            for c in \(known); do [ "$3" = "$c" ] && exit 0; done
            exit 1
            """)
        #expect(try await call(sb, "leave_context \(current)").status == 0)
        #expect(sb.calls.last == "docker context use \(expected)")
    }

    // MARK: - app_pids

    /// An app (100) and two commands (200, 300) have the process name ColimaBar.
    private func stubRunningProcesses(_ sb: ScriptSandbox) throws {
        try sb.stub("pgrep", "printf '100\\n200\\n300\\n'")
        try sb.stubProcesses([
            .init(pid: 100, age: 60, command: "/Applications/ColimaBar.app/Contents/MacOS/ColimaBar"),
            .init(pid: 200, age: 5, command: "/Applications/ColimaBar.app/Contents/MacOS/ColimaBar --cli start"),
            .init(
                pid: 300, age: 5, command: "/Applications/ColimaBar.app/Contents/MacOS/ColimaBar --cli status --json"),
        ])
    }

    @Test func theAppPIDsIgnoreRunningCommands() async throws {
        let sb = try ScriptSandbox()
        try stubRunningProcesses(sb)
        let r = try await call(sb, "app_pids")
        #expect(r.status == 0)
        #expect(r.out == "100\n")
    }

    @Test func onlyACommandRunningIsNotTheApp() async throws {
        let sb = try ScriptSandbox()
        try sb.stub("pgrep", "printf '200\\n'")
        try sb.stubProcesses([.init(pid: 200, age: 5, command: "/x/ColimaBar --cli start")])
        let r = try await call(sb, "app_pids; app_running")
        #expect(r.status == 1)
        #expect(r.out.isEmpty)
    }

    @Test func theAppCountsAsRunningWhileItsProcessExists() async throws {
        let sb = try ScriptSandbox()
        try stubRunningProcesses(sb)
        #expect(try await call(sb, "app_running").status == 0)
    }

    @Test func stoppingTheAppSignalsTheAppAndNotTheCommand() async throws {
        let sb = try ScriptSandbox()
        try stubRunningProcesses(sb)
        // The function replaces the builtin kill, so the test signals no process.
        let r = try await call(sb, "kill() { echo \"kill $*\"; }; term_app")
        #expect(r.status == 0)
        #expect(r.out == "kill -TERM 100\n")
    }

    // MARK: - The certificate authority of HTTPS

    private let foundTwice =
        "SHA-256 hash: AAAA\nSHA-1 hash: 0123456789ABCDEF0123456789ABCDEF01234567\nkeychain: \"x\"\nSHA-256 hash: BBBB\nSHA-1 hash: FEDCBA9876543210FEDCBA9876543210FEDCBA98"

    @Test func theCAHashesComeFromTheOutputOfSecurity() async throws {
        let sb = try ScriptSandbox()
        let r = try await sb.bash(
            ["-c", "set -uo pipefail; . '\(try helpers(sb))'; colimabar_ca_hashes /some/keychain"],
            env: ["STUB_SECURITY_FIND": foundTwice])
        #expect(
            r.out.split(separator: "\n") == [
                "0123456789ABCDEF0123456789ABCDEF01234567", "FEDCBA9876543210FEDCBA9876543210FEDCBA98",
            ])
        #expect(sb.calls == ["security find-certificate -a -Z -c ColimaBar Local CA /some/keychain"])
        // No certificate: no hash and no error.
        let none = try await sb.bash(["-c", "set -uo pipefail; . '\(try helpers(sb))'; colimabar_ca_hashes /k"])
        #expect(none.status == 0 && none.out.isEmpty)
    }

    /// The block of the script that removes the certificate authority.
    private func removalBlock(_ sb: ScriptSandbox) throws -> String {
        let text = try script()
        let start = try #require(text.range(of: "# BEGIN ca removal"))
        let end = try #require(text.range(of: "# END ca removal"))
        let path = sb.root + "/removal.sh"
        try String(text[start.lowerBound..<end.upperBound]).write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    private func runRemoval(_ sb: ScriptSandbox, env: [String: String] = [:]) async throws -> (
        status: Int32, out: String
    ) {
        try await sb.bash(
            ["-c", "set -uo pipefail; . '\(try helpers(sb))'; . '\(try removalBlock(sb))' 2>&1"],
            env: ["STUB_SECURITY_FIND": foundTwice].merging(env) { $1 })
    }

    @Test func theScriptDeletesTheCertificateAndItsTrustAndTheFolders() async throws {
        let sb = try ScriptSandbox()
        try sb.write("Library/Application Support/ColimaBar/domains/ca-key.raw", "key")
        try sb.write("Library/Application Support/ColimaBar/domains.new/ca-key.raw", "half-written")
        try sb.write("Library/Caches/com.imohitkr.ColimaBar/tls/tls-1.keychain-db", "kc")
        try sb.write("Library/Application Support/Other/keep.txt", "keep")
        let r = try await runRemoval(sb)
        #expect(r.status == 0)
        let keychain = sb.home + "/Library/Keychains/login.keychain-db"
        #expect(
            sb.calls == [
                "security find-certificate -a -Z -c ColimaBar Local CA \(keychain)",
                "security delete-certificate -t -Z 0123456789ABCDEF0123456789ABCDEF01234567 \(keychain)",
                "security delete-certificate -t -Z FEDCBA9876543210FEDCBA9876543210FEDCBA98 \(keychain)",
            ])
        let fm = FileManager.default
        // The folders of ColimaBar are empty after the removal, so they go too.
        #expect(!fm.fileExists(atPath: sb.home + "/Library/Application Support/ColimaBar"))
        #expect(!fm.fileExists(atPath: sb.home + "/Library/Caches/com.imohitkr.ColimaBar"))
        #expect(fm.fileExists(atPath: sb.home + "/Library/Application Support/Other/keep.txt"))
    }

    @Test func theScriptKeepsOtherFilesInTheFoldersOfColimaBar() async throws {
        let sb = try ScriptSandbox()
        try sb.write("Library/Application Support/ColimaBar/domains/ca-key.raw", "key")
        try sb.write("Library/Application Support/ColimaBar/other-feature/data.json", "{}")
        try sb.write("Library/Caches/com.imohitkr.ColimaBar/tls/tls-1.keychain-db", "kc")
        try sb.write("Library/Caches/com.imohitkr.ColimaBar/fsCachedData/entry", "cache")
        let r = try await runRemoval(sb)
        #expect(r.status == 0)
        let fm = FileManager.default
        let support = sb.home + "/Library/Application Support/ColimaBar"
        let caches = sb.home + "/Library/Caches/com.imohitkr.ColimaBar"
        #expect(!fm.fileExists(atPath: support + "/domains"))
        #expect(!fm.fileExists(atPath: caches + "/tls"))
        #expect(fm.fileExists(atPath: support + "/other-feature/data.json"))
        #expect(fm.fileExists(atPath: caches + "/fsCachedData/entry"))
    }

    @Test func theKeyGoesEvenWhenSecurityCannotDeleteTheCertificate() async throws {
        let sb = try ScriptSandbox()
        try sb.write("Library/Application Support/ColimaBar/domains/ca-key.raw", "key")
        let r = try await runRemoval(sb, env: ["STUB_SECURITY_DELETE_EXIT": "1"])
        #expect(r.status == 0)
        #expect(!FileManager.default.fileExists(atPath: sb.home + "/Library/Application Support/ColimaBar"))
        #expect(sb.calls.filter { $0.contains("delete-certificate") }.count == 2)
        // The script says so for each certificate that it could not remove.
        let message = "Could not remove the ColimaBar certificate authority. Remove it in Keychain Access."
        #expect(r.out.components(separatedBy: message).count == 3)
    }

    @Test func theRemovalDeletesTheKeyBeforeItAsksSecurity() throws {
        let text = try script()
        let rm = try #require(text.range(of: "rm -rf \"$SUPPORT_DIR/domains\""))
        let del = try #require(text.range(of: "security delete-certificate -t -Z"))
        #expect(rm.lowerBound < del.lowerBound)
    }

    @Test func theScriptUsesTheHelpers() throws {
        let text = try script()
        // It switches away from and removes only colimabar and the contexts of colimabar_contexts.
        #expect(text.contains("OUR_CONTEXTS=(colimabar $(colimabar_contexts))"))
        #expect(text.contains("for ctx in \"${OUR_CONTEXTS[@]}\"; do"))
        #expect(!text.contains("colimabar-*)"))
        #expect(text.contains("leave_context \"$ctx\""))
        // The names are read before the cache folder goes away.
        let read = try #require(text.range(of: "PROFILE_NAMES=($(profile_socket_names))"))
        let rm = try #require(text.range(of: "rm -rf ~/Applications/ColimaBar.app"))
        let link = try #require(text.range(of: "link_profile_sockets ${PROFILE_NAMES[@]"))
        #expect(read.lowerBound < rm.lowerBound && rm.lowerBound < link.lowerBound)
    }

    // MARK: - The links of the command

    private let suffix = "/ColimaBar.app/Contents/Resources/bin/colimabar"

    @Test func onlyAnOwnLinkIsRemoved() async throws {
        let sb = try ScriptSandbox()
        let fm = FileManager.default
        for dir in ["a", "b", "c", "d"] {
            try fm.createDirectory(atPath: "\(sb.root)/\(dir)", withIntermediateDirectories: true)
        }
        symlink("/Applications\(suffix)", sb.root + "/a/colimabar")  // ours
        symlink("/usr/bin/true", sb.root + "/b/colimabar")  // a link of the user
        fm.createFile(atPath: sb.root + "/c/colimabar", contents: nil)  // a file
        let r = try await call(sb, "remove_command_links '\(sb.root)/a' '\(sb.root)/b' '\(sb.root)/c' '\(sb.root)/d'")
        #expect(r.status == 0 && r.out == "Removed \(sb.root)/a/colimabar\n")
        #expect(!fm.fileExists(atPath: sb.root + "/a/colimabar"))
        #expect((try? fm.destinationOfSymbolicLink(atPath: sb.root + "/b/colimabar")) == "/usr/bin/true")
        #expect(fm.fileExists(atPath: sb.root + "/c/colimabar"))
    }

    @Test func aFolderThatTheUserCannotWriteNeedsSudo() async throws {
        let sb = try ScriptSandbox()
        let dir = sb.root + "/system-bin"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        symlink("/Applications\(suffix)", dir + "/colimabar")
        chmod(dir, 0o555)
        defer { chmod(dir, 0o755) }
        // A stub sudo that logs and does not run the command.
        try sb.stub("sudo", "printf 'sudo %s\\n' \"$*\" >> \"\(sb.log)\"\nexit 0")
        let r = try await call(sb, "remove_command_links '\(dir)'")
        #expect(r.out == "Removing \(dir)/colimabar (needs sudo)\n")
        #expect(sb.calls == ["sudo rm -f \(dir)/colimabar"])
    }

    @Test func theFoldersOfTheLinksAreTheOnesOfHomebrewTheInstallerAndTheUser() async throws {
        let sb = try ScriptSandbox()
        let r = try await call(sb, "command_link_dirs")
        #expect(
            r.out.split(separator: "\n").map(String.init)
                == ["/opt/homebrew/bin", "/usr/local/bin", sb.home + "/.local/bin", sb.home + "/bin"])
    }

    @Test func theScriptRemovesTheLinksAfterItRemovedTheApp() throws {
        let text = try script()
        let rm = try #require(text.range(of: "rm -rf ~/Applications/ColimaBar.app"))
        let links = try #require(text.range(of: "remove_command_links \"$dir\""))
        #expect(rm.lowerBound < links.lowerBound)
    }

    // MARK: Resolver files

    @Test func resolverFilesListsOnlyFilesWithOurMarker() async throws {
        let sb = try ScriptSandbox()
        let dir = sb.root + "/resolver dir"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try ResolverFile.content(port: 25000).write(toFile: dir + "/colima.internal", atomically: true, encoding: .utf8)
        try ResolverFile.content(port: 25001).write(toFile: dir + "/dev.test", atomically: true, encoding: .utf8)
        try "nameserver 127.0.0.1\n".write(toFile: dir + "/test", atomically: true, encoding: .utf8)
        try ("# other\n" + ResolverFile.marker + "\n").write(toFile: dir + "/late", atomically: true, encoding: .utf8)
        try (ResolverFile.marker + " more\n").write(toFile: dir + "/longer", atomically: true, encoding: .utf8)
        symlink(dir + "/dev.test", dir + "/link.test")
        try FileManager.default.createDirectory(atPath: dir + "/sub", withIntermediateDirectories: true)
        let r = try await call(sb, "own_resolver_files '\(dir)'")
        #expect(r.status == 0)
        #expect(r.out.split(separator: "\n").map(String.init) == [dir + "/colima.internal", dir + "/dev.test"])
        // A missing folder lists nothing and does not fail.
        let none = try await call(sb, "own_resolver_files '\(sb.root)/missing'")
        #expect(none.status == 0 && none.out.isEmpty)
    }

    @Test func theScriptMarkerEqualsTheSwiftMarker() throws {
        let text = try script()
        let line = try #require(text.split(separator: "\n").first { $0.hasPrefix("RESOLVER_MARKER=") })
        #expect(line == "RESOLVER_MARKER=\"\(ResolverFile.marker)\"")
    }

    @Test func theScriptRemovesResolverFilesWithSudoAndOnlyOurs() throws {
        let text = try script()
        #expect(text.contains("own_resolver_files /etc/resolver"))
        #expect(text.contains("sudo rm -f \"$f\""))
    }
}
