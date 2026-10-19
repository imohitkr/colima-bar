import CryptoKit
import Foundation
import Testing

@testable import ColimaBar

/// The `vm-config` action of `colima-ctl.sh`, with the stub tools of
/// ScriptSandbox. The sandbox has its own HOME: no real colima.yaml, no
/// real VM and no dialog.
@Suite struct ColimaCtlVMConfigTests {
    private let old = "cpu: 2\nnetwork:\n  dns: []\n"
    private let new = "cpu: 2\nnetwork:\n  dns: [1.1.1.1]\n"
    private let configPath = ".config/colima/work/colima.yaml"
    private let stagedPath = ".cache/colima-bar/colima.work.yaml.new"

    private func sha(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// A sandbox with colima.yaml and the staged file.
    private func sandbox(staged: String? = nil) throws -> ScriptSandbox {
        let sb = try ScriptSandbox()
        try sb.write(configPath, old)
        try sb.write(stagedPath, staged ?? new)
        return sb
    }

    private func vmConfig(
        _ sb: ScriptSandbox, staged: String? = nil, sha shaValue: String? = nil, env: [String: String] = [:]
    ) async throws -> (status: Int32, out: String) {
        try await sb.ctl(
            ["vm-config", staged ?? "\(sb.home)/\(stagedPath)", shaValue ?? sha(old)], env: env)
    }

    private func read(_ sb: ScriptSandbox, _ relative: String) -> String? {
        try? String(contentsOfFile: "\(sb.home)/\(relative)", encoding: .utf8)
    }

    private func colimaCalls(_ sb: ScriptSandbox) -> [String] { sb.calls.filter { $0.hasPrefix("colima ") } }

    private func dialogs(_ sb: ScriptSandbox) -> [String] { sb.calls.filter { $0.hasPrefix("osascript") } }

    @Test func aStoppedVMOnlyGetsTheNewFile() async throws {
        let sb = try sandbox()
        let r = try await vmConfig(sb)
        #expect(r.status == 0, "\(r.out)")
        #expect(read(sb, configPath) == new)
        #expect(colimaCalls(sb) == ["colima status --profile work"])
        #expect(dialogs(sb).isEmpty)
        #expect(read(sb, ".cache/colima-bar/colima.work.yaml.bak") == old)
        #expect(read(sb, stagedPath) == nil)
        #expect(sb.leavesNoLockOrBusyMarker)
    }

    private func mode(_ sb: ScriptSandbox, _ relative: String) -> Int? {
        let attrs = try? FileManager.default.attributesOfItem(atPath: "\(sb.home)/\(relative)")
        return (attrs?[.posixPermissions] as? NSNumber)?.intValue
    }

    @Test(arguments: [0o644, 0o600]) func colimaYAMLKeepsItsModeAfterAStoppedVMApply(original: Int) async throws {
        let sb = try sandbox()
        try FileManager.default.setAttributes(
            [.posixPermissions: original], ofItemAtPath: "\(sb.home)/\(configPath)")
        let r = try await vmConfig(sb)
        #expect(r.status == 0, "\(r.out)")
        #expect(read(sb, configPath) == new)
        #expect(mode(sb, configPath) == original)
    }

    @Test func aRunningVMAsksThenRestarts() async throws {
        let sb = try sandbox()
        let r = try await vmConfig(sb, env: ["STUB_COLIMA_STATUS": "0"])
        #expect(r.status == 0, "\(r.out)")
        #expect(dialogs(sb).count == 1)
        #expect(dialogs(sb)[0].contains("Apply the new VM settings to profile 'work'? Colima will restart the VM"))
        #expect(
            colimaCalls(sb) == [
                "colima status --profile work", "colima status --profile work", "colima status --profile work",
                "colima stop --profile work", "colima start --profile work",
            ])
        #expect(read(sb, configPath) == new)
        #expect(read(sb, ".cache/colima-bar/colima.work.yaml.bak") == old)
        #expect(read(sb, stagedPath) == nil)
        #expect(r.out.contains("COLIMABAR_STARTED"))
        #expect(sb.leavesNoLockOrBusyMarker)
    }

    @Test func aCancelledDialogChangesNothing() async throws {
        let sb = try sandbox()
        let r = try await vmConfig(sb, env: ["STUB_COLIMA_STATUS": "0", "STUB_OSASCRIPT_EXIT": "1"])
        #expect(r.status == 2)
        #expect(read(sb, configPath) == old)
        #expect(!colimaCalls(sb).contains { $0.hasPrefix("colima stop") || $0.hasPrefix("colima start") })
        #expect(read(sb, stagedPath) == nil)
        #expect(sb.leavesNoLockOrBusyMarker)
    }

    @Test func aFileThatChangedSinceTheEditIsRefused() async throws {
        let sb = try sandbox()
        let r = try await vmConfig(sb, sha: sha("cpu: 4\n"))
        #expect(r.status == 1)
        #expect(
            r.out.contains(
                "COLIMABAR_NOTIFY:colima.yaml of profile 'work' changed outside ColimaBar. Nothing changed. Try again.")
        )
        #expect(read(sb, configPath) == old)
        #expect(read(sb, ".cache/colima-bar/colima.work.yaml.bak") == nil)
        #expect(read(sb, stagedPath) == nil)
        #expect(!colimaCalls(sb).contains { $0.hasPrefix("colima stop") })
    }

    @Test func aMissingShaIsRefused() async throws {
        let sb = try sandbox()
        let r = try await sb.ctl(["vm-config", "\(sb.home)/\(stagedPath)"])
        #expect(r.status == 1)
        #expect(read(sb, configPath) == old)
    }

    @Test func aFileThatChangedWhileTheDialogWasOpenIsRefused() async throws {
        let sb = try sandbox()
        // The stub dialog changes colima.yaml, as if an editor saved it.
        try sb.stub(
            "osascript", "printf 'x' >> \"\(sb.home)/\(configPath)\"\nexit 0")
        let r = try await vmConfig(sb, env: ["STUB_COLIMA_STATUS": "0"])
        #expect(r.status == 1)
        #expect(read(sb, configPath) == old + "x")
        #expect(!colimaCalls(sb).contains { $0.hasPrefix("colima stop") })
    }

    @Test func aVMThatDoesNotStartGetsTheOldFileBack() async throws {
        let sb = try sandbox()
        try sb.stub(
            "colima",
            """
            printf 'colima %s\\n' "$*" >> "\(sb.log)"
            [ "$1" = start ] && exit 1
            exit 0
            """)
        let r = try await vmConfig(sb)
        #expect(r.status == 1)
        #expect(read(sb, configPath) == old)
        #expect(
            r.out.contains(
                "The VM of profile 'work' did not start with the new settings - see ~/.cache/colima-bar/ctl.log. ColimaBar put the old colima.yaml back. Start the VM to use it."
            ))
        // It does not try to start the VM again.
        #expect(colimaCalls(sb).filter { $0.hasPrefix("colima start") }.count == 1)
        #expect(read(sb, stagedPath) == nil)
        #expect(sb.leavesNoLockOrBusyMarker)
    }

    @Test func aFileOutsideTheStateFolderIsRefused() async throws {
        let sb = try sandbox()
        try sb.write("elsewhere/colima.work.yaml.new", new)
        let other = "\(sb.home)/elsewhere/colima.work.yaml.new"
        let r = try await vmConfig(sb, staged: other)
        #expect(r.status == 1)
        #expect(r.out.contains("COLIMABAR_NOTIFY:Invalid VM settings file for profile 'work'. Nothing changed."))
        #expect(read(sb, configPath) == old)
        // The script does not remove a file that is not its own.
        #expect(read(sb, "elsewhere/colima.work.yaml.new") == new)
    }

    @Test func aStagedFileOfAnotherProfileIsRefused() async throws {
        let sb = try sandbox()
        try sb.write(".cache/colima-bar/colima.other.yaml.new", new)
        let r = try await vmConfig(sb, staged: "\(sb.home)/.cache/colima-bar/colima.other.yaml.new")
        #expect(r.status == 1)
        #expect(read(sb, configPath) == old)
    }

    @Test func aPathWithDotDotIsRefused() async throws {
        let sb = try sandbox()
        let r = try await vmConfig(sb, staged: "\(sb.home)/.cache/colima-bar/../colima-bar/colima.work.yaml.new")
        #expect(r.status == 1)
        #expect(read(sb, configPath) == old)
    }

    @Test func aLinkInPlaceOfTheStagedFileIsRefused() async throws {
        let sb = try sandbox()
        try sb.write("target.yaml", "cpu: 99\n")
        let staged = "\(sb.home)/\(stagedPath)"
        try FileManager.default.removeItem(atPath: staged)
        try FileManager.default.createSymbolicLink(atPath: staged, withDestinationPath: "\(sb.home)/target.yaml")
        let r = try await vmConfig(sb)
        #expect(r.status == 1)
        #expect(read(sb, configPath) == old)
        #expect(read(sb, "target.yaml") == "cpu: 99\n")
    }

    @Test func aVMThatStateDiffersFromTheExpectedOneChangesNothing() async throws {
        // ColimaBar expected a running VM, but it is stopped: no dialog may open.
        let sb = try sandbox()
        let r = try await vmConfig(sb, env: ["COLIMABAR_EXPECT_RUNNING": "1"])
        #expect(r.status == 1)
        #expect(r.out.contains("The VM of profile 'work' started or stopped. Nothing changed. Try again."))
        #expect(read(sb, configPath) == old)
        #expect(read(sb, stagedPath) == nil)
    }

    @Test func aMissingColimaYAMLChangesNothing() async throws {
        let sb = try ScriptSandbox()
        try sb.write(stagedPath, new)
        let r = try await vmConfig(sb)
        #expect(r.status == 1)
        #expect(read(sb, configPath) == nil)
    }

    @Test func aStartInProgressChangesNothing() async throws {
        let sb = try sandbox()
        try sb.stub("pgrep", "echo 4242")
        try sb.stubProcesses([
            ScriptSandbox.FakeProcess(pid: 4242, age: 5, command: "/opt/homebrew/bin/colima start --profile work")
        ])
        let r = try await vmConfig(sb)
        #expect(r.status == 1)
        #expect(read(sb, configPath) == old)
    }

    @Test func aTermSignalDuringTheRestartGetsTheOldFileBack() async throws {
        let sb = try sandbox()
        // The stub start sends TERM to the script, as ColimaBar's time limit does, then hangs.
        try sb.stub(
            "colima",
            """
            printf 'colima %s\\n' "$*" >> "\(sb.log)"
            [ "$1" = status ] && exit "${STUB_COLIMA_STATUS:-1}"
            if [ "$1" = start ]; then
              kill -TERM "$(cat "$HOME/.cache/colima-bar/lock.work/pid")"
              exec sleep 5
            fi
            exit 0
            """)
        let r = try await vmConfig(sb, env: ["STUB_COLIMA_STATUS": "0"])
        #expect(r.status == 143, "\(r.out)")
        #expect(read(sb, configPath) == old)
        #expect(r.out.contains("ColimaBar put the old colima.yaml back. A copy is in "))
        #expect(read(sb, stagedPath) == nil)
        #expect(sb.leavesNoLockOrBusyMarker)
    }

    @Test func aStopThatFailsChangesNothingAndSaysSo() async throws {
        let sb = try sandbox()
        try sb.stub(
            "colima",
            """
            printf 'colima %s\\n' "$*" >> "\(sb.log)"
            [ "$1" = status ] && exit 0
            [ "$1" = stop ] && exit 1
            exit 0
            """)
        let r = try await vmConfig(sb)
        #expect(r.status == 1)
        #expect(read(sb, configPath) == old)
        #expect(
            r.out.contains(
                "ColimaBar could not stop the VM of profile 'work', so nothing changed - see ~/.cache/colima-bar/ctl.log."
            ))
        #expect(!r.out.contains("did not start"))
        #expect(!colimaCalls(sb).contains { $0.hasPrefix("colima start") })
        #expect(sb.leavesNoLockOrBusyMarker)
    }

    @Test func anUpgradeNoteAsksBeforeTheRestartDialog() async throws {
        let sb = try sandbox()
        let r = try await vmConfig(
            sb,
            env: [
                "STUB_COLIMA_STATUS": "0", "STUB_OSASCRIPT_OUT": "Continue",
                "COLIMABAR_UPGRADE_NOTE": "Colima changed since the last good start.",
            ])
        #expect(r.status == 0, "\(r.out)")
        #expect(dialogs(sb).count == 2)
        #expect(dialogs(sb)[0].contains("Colima changed since the last good start."))
        #expect(dialogs(sb)[1].contains("Apply the new VM settings to profile 'work'?"))
        #expect(read(sb, configPath) == new)
    }

    @Test func aCancelledUpgradeNoteChangesNothing() async throws {
        let sb = try sandbox()
        let r = try await vmConfig(
            sb,
            env: [
                "STUB_COLIMA_STATUS": "0", "STUB_OSASCRIPT_EXIT": "1",
                "STUB_OSASCRIPT_ERR": "execution error: User canceled. (-128)",
                "COLIMABAR_UPGRADE_NOTE": "Colima changed.",
            ])
        #expect(r.status == 2)
        #expect(dialogs(sb).count == 1)
        #expect(read(sb, configPath) == old)
    }

    @Test func aVMThatStopsWhileTheDialogIsOpenChangesNothing() async throws {
        let sb = try sandbox()
        let flag = "\(sb.home)/dialog-closed"
        try sb.stub("osascript", "printf 'osascript %s\\n' \"$*\" >> \"\(sb.log)\"\ntouch \"\(flag)\"\nexit 0")
        try sb.stub(
            "colima",
            """
            printf 'colima %s\\n' "$*" >> "\(sb.log)"
            [ "$1" = status ] && { [ -e "\(flag)" ] && exit 1; exit 0; }
            exit 0
            """)
        let r = try await vmConfig(sb)
        #expect(r.status == 1)
        #expect(r.out.contains("started or stopped while the dialog was open. Nothing changed. Try again."))
        #expect(read(sb, configPath) == old)
        #expect(!colimaCalls(sb).contains { $0.hasPrefix("colima stop") || $0.hasPrefix("colima start") })
    }

    @Test func aFolderInPlaceOfTheStagedFileIsRefused() async throws {
        let sb = try sandbox()
        let staged = "\(sb.home)/\(stagedPath)"
        try FileManager.default.removeItem(atPath: staged)
        try FileManager.default.createDirectory(atPath: staged, withIntermediateDirectories: false)
        let r = try await vmConfig(sb)
        #expect(r.status == 1)
        #expect(r.out.contains("COLIMABAR_NOTIFY:Invalid VM settings file for profile 'work'. Nothing changed."))
        #expect(read(sb, configPath) == old)
    }

    @Test func anOldFileThatCannotGoBackIsReportedWithTheBackupPath() async throws {
        let sb = try sandbox()
        let folder = "\(sb.home)/.config/colima/work"
        // The failed start makes the folder read-only, so the old file cannot go back.
        try sb.stub(
            "colima",
            """
            printf 'colima %s\\n' "$*" >> "\(sb.log)"
            [ "$1" = status ] && exit "${STUB_COLIMA_STATUS:-1}"
            [ "$1" = start ] && { chmod 555 "\(folder)"; exit 1; }
            exit 0
            """)
        let r = try await vmConfig(sb, env: ["STUB_COLIMA_STATUS": "0"])
        chmod(folder, 0o755)
        #expect(r.status == 1)
        #expect(read(sb, configPath) == new)
        #expect(
            r.out.contains(
                "ColimaBar could not put the old colima.yaml back. A copy is in \(sb.home)/.cache/colima-bar/colima.work.yaml.bak."
            ))
        #expect(read(sb, ".cache/colima-bar/colima.work.yaml.bak") == old)
    }

    @Test func theBusyMarkerNamesTheAction() async throws {
        let sb = try sandbox()
        try sb.stub(
            "colima",
            """
            printf 'colima %s\\n' "$*" >> "\(sb.log)"
            [ "$1" = status ] && exit 0
            [ "$1" = stop ] && head -n 1 "$HOME/.cache/colima-bar/busy.work" > "$HOME/label.txt"
            exit 0
            """)
        let r = try await vmConfig(sb)
        #expect(r.status == 0, "\(r.out)")
        #expect(read(sb, "label.txt") == "Applying VM settings\n")
    }
}
