import Foundation
import Testing

@testable import ColimaBar

/// Tests scripts/colimabar.sh in a fake bundle. The fake `ColimaBar` prints
/// its arguments and exits with `STUB_EXIT`.
@Suite struct CLIWrapperScriptTests {
    private let wrapper = ScriptSandbox.repo.appendingPathComponent("scripts/colimabar.sh").path

    /// Makes `<folder>/<app>/Contents/{MacOS/ColimaBar, Resources/bin/colimabar}`
    /// and returns the path of the command.
    private func bundle(in folder: String, app: String = "ColimaBar.app") throws -> String {
        let fm = FileManager.default
        let macOS = "\(folder)/\(app)/Contents/MacOS"
        let bin = "\(folder)/\(app)/Contents/Resources/bin"
        try fm.createDirectory(atPath: macOS, withIntermediateDirectories: true)
        try fm.createDirectory(atPath: bin, withIntermediateDirectories: true)
        let binary = "\(macOS)/ColimaBar"
        try "#!/bin/bash\nprintf '%s\\n' \"$@\"\nexit \"${STUB_EXIT:-0}\"\n".write(
            toFile: binary, atomically: true, encoding: .utf8)
        chmod(binary, 0o755)
        let command = "\(bin)/colimabar"
        try fm.copyItem(atPath: wrapper, toPath: command)
        chmod(command, 0o755)
        return command
    }

    private func run(_ sb: ScriptSandbox, _ command: String, _ args: [String] = [], exit code: Int = 0) async throws
        -> (status: Int32, out: String)
    {
        try await sb.bash([command] + args, env: ["STUB_EXIT": String(code)])
    }

    @Test func theWrapperStartsTheAppBinaryInCommandLineMode() async throws {
        let sb = try ScriptSandbox()
        let command = try bundle(in: sb.root)
        let r = try await run(sb, command, ["status", "--json"])
        #expect(r.status == 0)
        #expect(r.out == "--cli\nstatus\n--json\n")
    }

    @Test func argumentsWithSpacesAndQuotesArriveWhole() async throws {
        let sb = try ScriptSandbox()
        let command = try bundle(in: sb.root)
        let r = try await run(sb, command, ["diagnostics", "my folder/it's here"])
        #expect(r.out == "--cli\ndiagnostics\nmy folder/it's here\n")
    }

    @Test func theExitCodeOfTheAppPassesThrough() async throws {
        let sb = try ScriptSandbox()
        let command = try bundle(in: sb.root)
        for code in [0, 1, 2, 3, 130] {
            #expect(try await run(sb, command, ["x"], exit: code).status == Int32(code))
        }
    }

    @Test func aRelativeLinkWorks() async throws {
        let sb = try ScriptSandbox()
        _ = try bundle(in: sb.root)
        try FileManager.default.createDirectory(atPath: sb.root + "/links", withIntermediateDirectories: true)
        symlink("../ColimaBar.app/Contents/Resources/bin/colimabar", sb.root + "/links/colimabar")
        let r = try await run(sb, sb.root + "/links/colimabar", ["status"])
        #expect(r.status == 0 && r.out == "--cli\nstatus\n")
    }

    @Test func aChainOfLinksWorks() async throws {
        let sb = try ScriptSandbox()
        let command = try bundle(in: sb.root)
        try FileManager.default.createDirectory(atPath: sb.root + "/one", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: sb.root + "/two", withIntermediateDirectories: true)
        symlink(command, sb.root + "/one/colimabar")
        symlink("../one/colimabar", sb.root + "/two/colimabar")
        let r = try await run(sb, sb.root + "/two/colimabar", ["status"])
        #expect(r.status == 0 && r.out == "--cli\nstatus\n")
    }

    @Test func aFolderWithASpaceWorks() async throws {
        let sb = try ScriptSandbox()
        let folder = sb.root + "/My Apps"
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let command = try bundle(in: folder)
        try FileManager.default.createDirectory(atPath: sb.root + "/bin dir", withIntermediateDirectories: true)
        symlink(command, sb.root + "/bin dir/colimabar")
        let r = try await run(sb, sb.root + "/bin dir/colimabar", ["version"])
        #expect(r.status == 0 && r.out == "--cli\nversion\n")
    }

    @Test func aRenamedAppFolderWorks() async throws {
        // The wrapper finds the app by the folders around itself, not by name.
        let sb = try ScriptSandbox()
        let command = try bundle(in: sb.root, app: "Renamed.app")
        let r = try await run(sb, command, ["status"])
        #expect(r.status == 0)
    }

    @Test func outsideABundleTheWrapperFailsWithExitOne() async throws {
        let sb = try ScriptSandbox()
        let loose = sb.root + "/loose"
        try FileManager.default.createDirectory(atPath: loose, withIntermediateDirectories: true)
        try FileManager.default.copyItem(atPath: wrapper, toPath: loose + "/colimabar")
        chmod(loose + "/colimabar", 0o755)
        let r = try await run(sb, loose + "/colimabar", ["status"])
        #expect(r.status == 1)
        #expect(r.out.isEmpty)  // the message goes to stderr
    }

    @Test func aBundleWithoutTheBinaryFailsWithExitOne() async throws {
        let sb = try ScriptSandbox()
        let command = try bundle(in: sb.root)
        try FileManager.default.removeItem(atPath: sb.root + "/ColimaBar.app/Contents/MacOS/ColimaBar")
        #expect(try await run(sb, command, ["status"]).status == 1)
    }
}
