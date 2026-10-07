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

    private func call(_ sb: ScriptSandbox, _ code: String) throws -> (status: Int32, out: String) {
        let h = try helpers(sb)
        return try sb.bash([
            "-c", "set -uo pipefail; PROFILES_DIR=\"$HOME/.cache/colima-bar/profiles\"; . '\(h)'; \(code)",
        ])
    }

    @Test func theHelperBlockOnlyDefinesFunctions() throws {
        let sb = try ScriptSandbox()
        let r = try call(sb, "true")
        #expect(r.status == 0 && r.out.isEmpty)
        #expect(sb.calls.isEmpty)  // sourcing ran no tool
    }

    @Test func contextsAreEveryColimabarProfileContext() throws {
        let sb = try ScriptSandbox()
        try sb.stub(
            "docker",
            "printf 'colimabar\\ncolimabar-work\\ncolimabar-a.b\\ndefault\\ncolima-work\\nmycolimabar-x\\ncolimabar-\\n'"
        )
        let r = try call(sb, "colimabar_contexts")
        #expect(r.out.split(separator: "\n") == ["colimabar-work", "colimabar-a.b"])
        // No docker CLI: no contexts, no error.
        try FileManager.default.removeItem(atPath: sb.bin + "/docker")
        #expect(try call(sb, "colimabar_contexts").out.isEmpty)
    }

    @Test func profileSocketsAreFoundAndLinkedToTheirProfiles() throws {
        let sb = try ScriptSandbox()
        let dir = sb.home + "/.cache/colima-bar/profiles"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: dir + "/work.sock", contents: nil)
        symlink("/nonexistent", dir + "/b.sock")
        FileManager.default.createFile(atPath: dir + "/x.sock.tmp", contents: nil)
        FileManager.default.createFile(atPath: dir + "/notes.txt", contents: nil)
        let names = try call(sb, "profile_socket_names").out.split(separator: "\n")
        #expect(names == ["b", "work"])

        try FileManager.default.removeItem(atPath: sb.home + "/.cache/colima-bar")
        #expect(try call(sb, "link_profile_sockets work b").status == 0)
        let fm = FileManager.default
        #expect(
            try fm.destinationOfSymbolicLink(atPath: dir + "/work.sock") == sb.home + "/.config/colima/work/docker.sock"
        )
        #expect(try fm.destinationOfSymbolicLink(atPath: dir + "/b.sock") == sb.home + "/.config/colima/b/docker.sock")
        #expect(try call(sb, "link_profile_sockets").status == 0)  // no profiles: nothing to do
    }

    @Test func theScriptUsesTheHelpers() throws {
        let text = try script()
        #expect(text.contains("for ctx in $(colimabar_contexts); do"))
        #expect(text.contains("colimabar|colimabar-*)"))
        // The names are read before the cache folder goes away.
        let read = try #require(text.range(of: "PROFILE_NAMES=($(profile_socket_names))"))
        let rm = try #require(text.range(of: "rm -rf ~/Applications/ColimaBar.app"))
        let link = try #require(text.range(of: "link_profile_sockets ${PROFILE_NAMES[@]"))
        #expect(read.lowerBound < rm.lowerBound && rm.lowerBound < link.lowerBound)
    }
}
