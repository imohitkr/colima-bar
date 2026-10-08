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
}
