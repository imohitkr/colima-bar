import Foundation
import Testing

@testable import ColimaBar

/// Tests the helper functions of scripts/install.sh. The tests source only
/// the block between "# BEGIN helpers" and "# END helpers", which defines
/// functions and runs nothing. The full script downloads and installs an app,
/// so it never runs in a test.
@Suite struct InstallScriptTests {
    private let suffix = "/ColimaBar.app/Contents/Resources/bin/colimabar"

    private func helpers(_ sb: ScriptSandbox) throws -> String {
        let text = try String(
            contentsOf: ScriptSandbox.repo.appendingPathComponent("scripts/install.sh"), encoding: .utf8)
        let start = try #require(text.range(of: "# BEGIN helpers"))
        let end = try #require(text.range(of: "# END helpers"))
        let path = sb.root + "/install-helpers.sh"
        try String(text[start.lowerBound..<end.upperBound]).write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    /// Runs `code` after the helpers. `path` is the PATH, after the stub folder.
    private func call(_ sb: ScriptSandbox, _ code: String, path: [String] = []) async throws -> (
        status: Int32, out: String
    ) {
        let h = try helpers(sb)
        let full = ([sb.bin] + path + ["/usr/bin", "/bin"]).joined(separator: ":")
        return try await sb.bash(["-c", "set -uo pipefail; . '\(h)'; \(code)"], env: ["PATH": full])
    }

    /// A command that works: an executable file at `<root>/<place>/ColimaBar.app/.../colimabar`.
    private func wrapper(_ sb: ScriptSandbox, place: String = "apps") throws -> String {
        let dir = "\(sb.root)/\(place)/ColimaBar.app/Contents/Resources/bin"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let path = dir + "/colimabar"
        try "#!/bin/bash\n".write(toFile: path, atomically: true, encoding: .utf8)
        chmod(path, 0o755)
        return path
    }

    private func folder(_ path: String) throws {
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    }

    @Test func theHelperBlockOnlyDefinesFunctions() async throws {
        let sb = try ScriptSandbox()
        let r = try await call(sb, "true")
        #expect(r.status == 0 && r.out.isEmpty)
        #expect(sb.calls.isEmpty)
    }

    // MARK: - is_own_link

    @Test func aLinkToTheCommandOfAnAppIsOurs() async throws {
        let sb = try ScriptSandbox()
        symlink("/Applications\(suffix)", sb.root + "/a")
        symlink("/opt/homebrew/Caskroom/colima-bar/0.10.0\(suffix)", sb.root + "/b")
        symlink("../x/ColimaBar.app/Contents/Resources/bin/colimabar", sb.root + "/c")  // dangling is fine
        for name in ["a", "b", "c"] {
            #expect(try await call(sb, "is_own_link '\(sb.root)/\(name)'").status == 0)
        }
    }

    @Test func otherFilesAreNotOurs() async throws {
        let sb = try ScriptSandbox()
        FileManager.default.createFile(atPath: sb.root + "/file", contents: nil)
        symlink("/usr/bin/true", sb.root + "/other")
        symlink("/Applications/Other.app/Contents/Resources/bin/colimabar", sb.root + "/lookalike")
        symlink("/Applications\(suffix)/extra", sb.root + "/longer")
        for name in ["file", "other", "lookalike", "longer", "missing"] {
            #expect(try await call(sb, "is_own_link '\(sb.root)/\(name)'").status == 1, "\(name) is not ours")
        }
    }

    // MARK: - command_dir

    @Test func theFolderIsLocalBinFirstThenBin() async throws {
        let sb = try ScriptSandbox()
        let local = sb.home + "/.local/bin", bin = sb.home + "/bin"
        try folder(local)
        try folder(bin)
        #expect(try await call(sb, "command_dir", path: [bin, local]).out == local + "\n")
        #expect(try await call(sb, "command_dir", path: [bin]).out == bin + "\n")
    }

    @Test func aFolderOutsidePathOrMissingOrNotWritableIsSkipped() async throws {
        let sb = try ScriptSandbox()
        let local = sb.home + "/.local/bin", bin = sb.home + "/bin"
        try folder(local)
        #expect(try await call(sb, "command_dir", path: [bin]).out.isEmpty)  // ~/bin missing, local not on PATH
        try folder(bin)
        chmod(bin, 0o555)
        defer { chmod(bin, 0o755) }
        #expect(try await call(sb, "command_dir", path: [bin]).out.isEmpty)  // not writable
    }

    // MARK: - link_command

    @Test func theCommandIsLinkedIntoAFolderInPath() async throws {
        let sb = try ScriptSandbox()
        let target = try wrapper(sb)
        let local = sb.home + "/.local/bin"
        try folder(local)
        let r = try await call(sb, "link_command '\(target)'", path: [local])
        #expect(r.status == 0)
        #expect(r.out == "Linked the colimabar command: \(local)/colimabar\n")
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: local + "/colimabar") == target)
    }

    @Test func aLinkThatWorksIsLeftAlone() async throws {
        let sb = try ScriptSandbox()
        let target = try wrapper(sb)
        let brew = sb.root + "/brew-bin"
        try folder(brew)
        symlink(target, brew + "/colimabar")
        let local = sb.home + "/.local/bin"
        try folder(local)
        let r = try await call(sb, "link_command '\(target)'", path: [brew, local])
        #expect(r.out == "The colimabar command is linked: \(brew)/colimabar\n")
        #expect(!FileManager.default.fileExists(atPath: local + "/colimabar"))
    }

    @Test func aBrokenLinkOfOursIsReplaced() async throws {
        let sb = try ScriptSandbox()
        let target = try wrapper(sb)
        let local = sb.home + "/.local/bin"
        try folder(local)
        symlink("/gone\(suffix)", local + "/colimabar")
        let r = try await call(sb, "link_command '\(target)'", path: [local])
        #expect(r.out.hasPrefix("Linked the colimabar command"))
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: local + "/colimabar") == target)
    }

    @Test func aColimabarThatIsNotOursIsNeverReplaced() async throws {
        let sb = try ScriptSandbox()
        let target = try wrapper(sb)
        let local = sb.home + "/.local/bin"
        try folder(local)
        // A script that works: `command -v` finds it.
        try "#!/bin/bash\n".write(toFile: local + "/colimabar", atomically: true, encoding: .utf8)
        chmod(local + "/colimabar", 0o755)
        let found = try await call(sb, "link_command '\(target)'", path: [local])
        #expect(found.out == "Notice: \(local)/colimabar is not a link of ColimaBar. The installer left it.\n")
        // A file that does not run: `command -v` skips it, and the installer still leaves it.
        chmod(local + "/colimabar", 0o644)
        let loose = try await call(sb, "link_command '\(target)'", path: [local])
        #expect(loose.out == "Notice: \(local)/colimabar is not a link of ColimaBar. The installer left it.\n")
        #expect(
            !(try FileManager.default.attributesOfItem(atPath: local + "/colimabar")[.type] as? FileAttributeType
                == .typeSymbolicLink))
    }

    @Test func withoutAFolderTheCommandPrintsTheSudoLineAndRunsNothing() async throws {
        let sb = try ScriptSandbox()
        let target = try wrapper(sb)
        try sb.stub("sudo", "printf 'sudo %s\\n' \"$*\" >> \"\(sb.log)\"\nexit 0")
        let r = try await call(sb, "link_command '\(target)'")
        #expect(r.out == "To use the colimabar command, run: sudo ln -sf '\(target)' /usr/local/bin/colimabar\n")
        #expect(sb.calls.isEmpty)  // the installer never uses sudo
    }

    @Test func aMissingCommandInTheAppChangesNothing() async throws {
        // An old release has no command.
        let sb = try ScriptSandbox()
        let local = sb.home + "/.local/bin"
        try folder(local)
        let r = try await call(sb, "link_command '\(sb.root)/none'", path: [local])
        #expect(r.status == 0 && r.out.isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: local).isEmpty)
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

    @Test func theScriptLinksTheCommandAfterTheInstall() throws {
        let text = try String(
            contentsOf: ScriptSandbox.repo.appendingPathComponent("scripts/install.sh"), encoding: .utf8)
        let installed = try #require(text.range(of: "echo \"Installed $dest/ColimaBar.app\""))
        let link = try #require(text.range(of: "link_command \"$dest/ColimaBar.app/Contents/Resources/bin/colimabar\""))
        let open = try #require(text.range(of: "open \"$dest/ColimaBar.app\""))
        #expect(installed.lowerBound < link.lowerBound && link.lowerBound < open.lowerBound)
    }
}
