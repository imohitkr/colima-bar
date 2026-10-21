import Foundation
import Testing

@testable import ColimaBar

/// The `vm-recreate` action of `colima-ctl.sh`, and the VM type arguments of
/// `profile-create`, with the stub tools of ScriptSandbox. The sandbox has its
/// own HOME: no real colima.yaml, no real VM and no dialog.
@Suite struct ColimaCtlRecreateTests {
    private let config = "cpu: 2\ndisk: 100\nmemory: 2\nrosetta: false\nvmType: vz\nmountType: virtiofs\n"
    private let yamlPath = ".config/colima/work/colima.yaml"
    private let state = ".cache/colima-bar"

    private func sandbox(_ text: String? = nil, qemu: Bool = true) throws -> ScriptSandbox {
        let sb = try ScriptSandbox()
        try sb.write(yamlPath, text ?? config)
        if qemu {
            try sb.stub("qemu-img", "exit 0")
            try sb.stub("qemu-system-aarch64", "exit 0")
        }
        return sb
    }

    private func recreate(
        _ sb: ScriptSandbox, _ vmType: String = "qemu", _ mountType: String = "sshfs", profile: String = "work",
        env: [String: String] = [:]
    ) async throws -> (status: Int32, out: String) {
        try await sb.ctl(
            ["vm-recreate", vmType, mountType], profile: profile,
            env: ["STUB_DELETE_DIR": "\(sb.home)/.config/colima/\(profile)"].merging(env) { $1 })
    }

    private func yaml(_ sb: ScriptSandbox, _ relative: String? = nil) -> String? {
        try? String(contentsOfFile: "\(sb.home)/\(relative ?? yamlPath)", encoding: .utf8)
    }

    private func exists(_ sb: ScriptSandbox, _ relative: String) -> Bool {
        FileManager.default.fileExists(atPath: "\(sb.home)/\(relative)")
    }

    /// The calls of `colima` besides `status`.
    private func vmCalls(_ sb: ScriptSandbox) -> [String] {
        sb.calls.filter { $0.hasPrefix("colima ") && !$0.hasPrefix("colima status") }
    }

    private func dialogs(_ sb: ScriptSandbox) -> String {
        sb.calls.filter { !$0.hasPrefix("colima ") && !$0.hasPrefix("docker ") }.joined(separator: "\n")
    }

    private func notices(_ r: (status: Int32, out: String)) -> [String] {
        r.out.split(separator: "\n").filter { $0.hasPrefix("COLIMABAR_NOTIFY:") }.map {
            String($0.dropFirst("COLIMABAR_NOTIFY:".count))
        }
    }

    // MARK: Order of the calls

    @Test func aRunningVMStopsDeletesWithoutDataAndStartsWithTheNewValues() async throws {
        let sb = try sandbox()
        let r = try await recreate(sb, env: ["STUB_COLIMA_STATUS": "0"])
        #expect(r.status == 0, "\(r.out)")
        #expect(
            vmCalls(sb) == [
                "colima stop --profile work", "colima delete --force --profile work", "colima start --profile work",
            ])
        #expect(!sb.calls.contains { $0.contains("--data") })
        let new = try #require(yaml(sb))
        #expect(new.contains("vmType: qemu\n") && new.contains("mountType: sshfs\n"))
        #expect(new.contains("cpu: 2\ndisk: 100\nmemory: 2\n"))
        #expect(yaml(sb, "\(state)/colima.work.yaml.before-recreate") == config)
        #expect(!exists(sb, "\(state)/colima.work.yaml.recreate"))
        #expect(sb.leavesNoLockOrBusyMarker)
        #expect(r.out.contains("COLIMABAR_STARTED"))
    }

    @Test func aStoppedVMStartsOnceThenStopsAgain() async throws {
        let sb = try sandbox()
        let r = try await recreate(sb)
        #expect(r.status == 0, "\(r.out)")
        #expect(
            vmCalls(sb) == [
                "colima delete --force --profile work", "colima start --profile work", "colima stop --profile work",
            ])
        #expect(dialogs(sb).contains("Colima starts the VM once to create it, then stops it again."))
    }

    @Test func aRunningVMDialogSaysThatTheVMStartsAgain() async throws {
        let sb = try sandbox()
        _ = try await recreate(sb, env: ["STUB_COLIMA_STATUS": "0"])
        #expect(dialogs(sb).contains("Then Colima starts the VM again with the same other settings."))
    }

    @Test func missingKeysAreAddedAtTheEndAlsoWithoutAFinalNewline() async throws {
        let sb = try sandbox("cpu: 2\ndisk: 100")
        let r = try await recreate(sb, "vz", "sshfs")
        #expect(r.status == 0, "\(r.out)")
        #expect(yaml(sb) == "cpu: 2\ndisk: 100\nvmType: vz\nmountType: sshfs\n")
    }

    @Test func vzWithNoMountTypeKeyChangesOnlyTheMountType() async throws {
        let sb = try sandbox("cpu: 2\nvmType: vz\n")
        let r = try await recreate(sb, "vz", "sshfs")
        #expect(r.status == 0, "\(r.out)")
        #expect(yaml(sb) == "cpu: 2\nvmType: vz\nmountType: sshfs\n")
    }

    // MARK: Refusals before any dialog

    @Test(arguments: [["vz", "9p"], ["qemu", "virtiofs"], ["krunkit", "sshfs"], ["", ""], ["vz", ""]])
    func aBadPairExitsBeforeTheLockAndAnyColimaCall(pair: [String]) async throws {
        let sb = try sandbox()
        let r = try await recreate(sb, pair[0], pair[1])
        #expect(r.status == 1)
        #expect(notices(r).first?.hasPrefix("Invalid VM type or mount type for profile 'work'") == true)
        #expect(sb.calls.isEmpty)
        #expect(sb.leavesNoLockOrBusyMarker)
        #expect(yaml(sb) == config)
    }

    @Test func theScriptAndTheAppAcceptTheSamePairs() throws {
        let text = try String(
            contentsOf: ScriptSandbox.repo.appendingPathComponent("scripts/colima-ctl.sh"), encoding: .utf8)
        let body = try #require(text.components(separatedBy: "recreate_pair_ok() {").dropFirst().first)
        let line = String(try #require(body.split(separator: "\n").first { $0.contains("vz:virtiofs") }))
        let script = Set(line.matches(of: /[a-z]+:[a-z0-9]+/).map { String($0.output) })
        let app = Set(VMTypeRules.vmTypes.flatMap { v in VMTypeRules.mountTypes(for: v).map { "\(v):\($0)" } })
        #expect(script == app)
    }

    @Test(arguments: ["colima", "colima-x"])
    func aNameThatColimaReadsAsAnotherProfileIsRefused(name: String) async throws {
        let sb = try ScriptSandbox()
        try sb.write(".config/colima/\(name)/colima.yaml", config)
        try sb.write(".config/colima/default/colima.yaml", config)
        let r = try await recreate(sb, profile: name)
        #expect(r.status == 1)
        #expect(
            notices(r).first
                == "Can't change the VM type of profile '\(name)'. Colima reads this name as a different profile.")
        #expect(sb.calls.isEmpty)
    }

    @Test func aMissingColimaYAMLIsRefused() async throws {
        let sb = try ScriptSandbox()
        try sb.write(".config/colima/default/colima.yaml", config)
        let r = try await recreate(sb)
        #expect(r.status == 1)
        #expect(notices(r).first?.contains("Its colima.yaml does not exist.") == true)
        #expect(sb.calls.isEmpty)
    }

    @Test func vzIsRefusedForAnX86VM() async throws {
        let sb = try sandbox(config + "arch: x86_64\n")
        let r = try await recreate(sb, "vz", "sshfs")
        #expect(r.status == 1)
        #expect(notices(r).first == "An x86_64 VM of profile 'work' needs the qemu VM type.")
        #expect(sb.calls.isEmpty)
    }

    /// A copy of the script whose PATH has the stubs and the system folders only,
    /// so a QEMU of the Mac does not count.
    private func withoutHomebrew(_ sb: ScriptSandbox, _ args: [String]) async throws -> (status: Int32, out: String) {
        let script = try sb.copy("colima-ctl.sh")
        let text = try String(contentsOfFile: script, encoding: .utf8)
        let pathLine = try #require(text.split(separator: "\n").first { $0.hasPrefix("export PATH=") })
        try text.replacingOccurrences(
            of: String(pathLine), with: "export PATH=\"\(sb.bin):/usr/bin:/bin:/usr/sbin:/sbin\""
        ).write(toFile: script, atomically: true, encoding: .utf8)
        return try await sb.bash([script] + args, env: ["COLIMABAR_PROFILE": "work", "COLIMABAR_APP": "1"])
    }

    @Test func qemuNeedsQEMU() async throws {
        let sb = try sandbox(qemu: false)
        let r = try await withoutHomebrew(sb, ["vm-recreate", "qemu", "sshfs"])
        #expect(r.status == 1)
        #expect(
            notices(r).first == "The qemu VM type needs QEMU. Install it with brew install qemu, then try again.")
        #expect(sb.calls.isEmpty)
    }

    @Test func theQEMUStubsLetQEMUPass() async throws {
        let sb = try sandbox()
        let r = try await recreate(sb)
        #expect(r.status == 0, "\(r.out)")
    }

    @Test func qemuIsRefusedForAReachableAddress() async throws {
        let sb = try sandbox(config + "network:\n  address: true\n  dns: []\n")
        let r = try await recreate(sb)
        #expect(r.status == 1)
        #expect(notices(r).first?.contains("has a reachable IP address. It needs the vz VM type.") == true)
        #expect(sb.calls.isEmpty)
    }

    @Test func qemuIsRefusedForBridgedNetworking() async throws {
        let sb = try sandbox(config + "network:\n  address: false\n  mode: bridged\n")
        let r = try await recreate(sb)
        #expect(r.status == 1)
        #expect(notices(r).first?.hasPrefix("Bridged networking with qemu needs socket_vmnet.") == true)
        #expect(sb.calls.isEmpty)
    }

    @Test func theSameTypesExitBeforeTheLock() async throws {
        let sb = try sandbox()
        let r = try await recreate(sb, "vz", "virtiofs")
        #expect(r.status == 1)
        #expect(notices(r).first == "profile 'work' uses vz and virtiofs already. Nothing changed.")
        #expect(sb.calls.isEmpty)
        #expect(sb.leavesNoLockOrBusyMarker)
    }

    @Test func noKeysCountAsVZWithItsDefaultMountType() async throws {
        let sb = try sandbox("cpu: 2\n")
        let r = try await recreate(sb, "vz", "virtiofs")
        #expect(r.status == 1)
        #expect(notices(r).first == "profile 'work' uses vz and virtiofs already. Nothing changed.")
        #expect(sb.calls.isEmpty)
    }

    @Test func aQEMUFileWithNoMountTypeCountsAsSSHFS() async throws {
        let sb = try sandbox("cpu: 2\nvmType: qemu\n")
        let r = try await recreate(sb, "qemu", "sshfs")
        #expect(r.status == 1)
        #expect(notices(r).first == "profile 'work' uses qemu and sshfs already. Nothing changed.")
    }

    // MARK: Dialog

    @Test func theDialogNamesTheProfileAndTheTypes() async throws {
        let sb = try sandbox()
        _ = try await recreate(sb)
        #expect(dialogs(sb).contains("Change the VM of profile 'work' from vz / virtiofs to qemu / sshfs?"))
    }

    @Test func aCancelledDialogChangesNothingAndLeavesNoCopy() async throws {
        let sb = try sandbox()
        let r = try await recreate(sb, env: ["STUB_OSASCRIPT_EXIT": "1"])
        #expect(r.status == 2)
        #expect(vmCalls(sb).isEmpty)
        #expect(yaml(sb) == config)
        let left = (try? FileManager.default.contentsOfDirectory(atPath: sb.home + "/" + state)) ?? []
        #expect(!left.contains { $0.contains("recreate") && $0.hasSuffix("yaml") })
        #expect(!left.contains { $0.hasSuffix(".recreate") || $0.hasSuffix(".before-recreate") })
        #expect(sb.leavesNoLockOrBusyMarker)
    }

    @Test func aStateChangeDuringTheDialogDeletesNothing() async throws {
        let sb = try sandbox()
        let r = try await recreate(sb, env: ["STUB_COLIMA_STATUS": "0", "STUB_OSASCRIPT_STOPS_VM": "1"])
        #expect(r.status == 1)
        #expect(notices(r).first?.contains("started or stopped while the dialog was open") == true)
        #expect(vmCalls(sb).isEmpty)
        #expect(yaml(sb) == config)
        #expect(!exists(sb, "\(state)/colima.work.yaml.recreate"))
    }

    @Test func theDialogSaysThatTheDataDiskStays() async throws {
        let sb = try sandbox()
        try sb.write(".config/colima/_lima/_disks/colima-work/datadisk", "")
        try sb.write(".config/colima/_store/colima-work.json", "{\n  \"disk_formatted\": true\n}")
        _ = try await recreate(sb)
        #expect(dialogs(sb).contains("Colima keeps the Docker data disk. Images, containers and volumes stay."))
        #expect(!dialogs(sb).contains("lost for good"))
    }

    @Test func withoutADataDiskTheDialogSaysThatDataIsLost() async throws {
        let sb = try sandbox(config + "kubernetes:\n  enabled: true\n")
        _ = try await recreate(sb)
        #expect(dialogs(sb).contains("This VM has no separate Docker data disk."))
        #expect(dialogs(sb).contains("lost for good"))
        #expect(dialogs(sb).contains("The Kubernetes cluster and its data are also deleted."))
    }

    @Test func aDiskThatIsNotFormattedCountsAsNoDataDisk() async throws {
        let sb = try sandbox()
        try sb.write(".config/colima/_lima/_disks/colima-work/datadisk", "")
        try sb.write(".config/colima/_store/colima-work.json", "{\"disk_formatted\": false}")
        _ = try await recreate(sb)
        #expect(dialogs(sb).contains("lost for good"))
    }

    @Test func rosettaTurnsOffForQEMU() async throws {
        let sb = try sandbox(config.replacingOccurrences(of: "rosetta: false", with: "rosetta: true"))
        let r = try await recreate(sb)
        #expect(r.status == 0, "\(r.out)")
        #expect(dialogs(sb).contains("Rosetta turns off, because it needs the vz VM type."))
        #expect(try #require(yaml(sb)).contains("rosetta: false\n"))
    }

    @Test func rosettaStaysForVZ() async throws {
        let sb = try sandbox(
            config.replacingOccurrences(of: "rosetta: false", with: "rosetta: true")
                .replacingOccurrences(of: "mountType: virtiofs", with: "mountType: sshfs"))
        let r = try await recreate(sb, "vz", "virtiofs")
        #expect(r.status == 0, "\(r.out)")
        #expect(!dialogs(sb).contains("Rosetta turns off"))
        #expect(try #require(yaml(sb)).contains("rosetta: true\n"))
    }

    // MARK: Failures

    @Test func aFailedStopChangesNothing() async throws {
        let sb = try sandbox()
        try sb.stub(
            "colima",
            """
            printf 'colima %s\\n' "$*" >> "\(sb.log)"
            [ "$1" = status ] && exit 0
            [ "$1" = stop ] && exit 1
            exit 0
            """)
        let r = try await recreate(sb)
        #expect(r.status == 1)
        #expect(
            notices(r).first?.hasPrefix("ColimaBar could not stop the VM of profile 'work', so nothing changed") == true
        )
        #expect(!sb.calls.contains { $0.hasPrefix("colima delete") })
        #expect(yaml(sb) == config)
        #expect(!exists(sb, "\(state)/colima.work.yaml.recreate"))
    }

    @Test func aFailedDeletePutsTheOldFileBack() async throws {
        let sb = try sandbox()
        try sb.stub(
            "colima",
            """
            printf 'colima %s\\n' "$*" >> "\(sb.log)"
            [ "$1" = status ] && exit 1
            [ "$1" = delete ] && { rm -rf "$STUB_DELETE_DIR"; exit 1; }
            exit 0
            """)
        let r = try await recreate(sb)
        #expect(r.status == 1)
        #expect(notices(r).first?.hasPrefix("Colima could not delete the VM of profile 'work'") == true)
        #expect(yaml(sb) == config)
        #expect(!sb.calls.contains { $0.hasPrefix("colima start") })
    }

    @Test func aFailedStartKeepsTheCopyAndNamesTheOldFile() async throws {
        let sb = try sandbox()
        try sb.stub(
            "colima",
            """
            printf 'colima %s\\n' "$*" >> "\(sb.log)"
            [ "$1" = status ] && exit 1
            [ "$1" = delete ] && rm -rf "$STUB_DELETE_DIR"
            [ "$1" = start ] && exit 1
            exit 0
            """)
        let r = try await recreate(sb)
        #expect(r.status == 1)
        let notice = try #require(notices(r).first)
        #expect(notice.hasPrefix("The VM of profile 'work' did not start with qemu / sshfs"))
        #expect(notice.contains("colima.work.yaml.before-recreate"))
        #expect(exists(sb, "\(state)/colima.work.yaml.recreate"))
        #expect(yaml(sb, "\(state)/colima.work.yaml.before-recreate") == config)
        // The new file is in place, so a start tries the new types.
        #expect(try #require(yaml(sb)).contains("vmType: qemu\n"))
    }

    @Test func aFailedLastStopNamesTheNewTypes() async throws {
        let sb = try sandbox()
        try sb.stub(
            "colima",
            """
            printf 'colima %s\\n' "$*" >> "\(sb.log)"
            [ "$1" = status ] && exit 1
            [ "$1" = delete ] && rm -rf "$STUB_DELETE_DIR"
            [ "$1" = stop ] && exit 1
            exit 0
            """)
        let r = try await recreate(sb)
        #expect(r.status == 1)
        #expect(
            notices(r).first?.hasPrefix(
                "The VM of profile 'work' now uses qemu / sshfs, but the stop failed") == true)
        #expect(!exists(sb, "\(state)/colima.work.yaml.recreate"))
    }

    @Test func aTermDuringTheDeleteRestoresColimaYAMLFromTheCopy() async throws {
        // `colima delete` removes the profile folder, then waits. The script
        // gets TERM there: colima.yaml is gone, so cleanup puts the copy back.
        let sb = try sandbox()
        let marker = sb.root + "/deleting"
        try sb.stub(
            "colima",
            """
            printf 'colima %s\\n' "$*" >> "\(sb.log)"
            [ "$1" = status ] && exit 1
            if [ "$1" = delete ]; then
              rm -rf "$STUB_DELETE_DIR"
              : > "\(marker)"
              exec sleep 30
            fi
            exit 0
            """)
        let script = try sb.copy("colima-ctl.sh")
        let r = try await sb.bash(
            [
                "-c",
                "/bin/bash \"$0\" vm-recreate qemu sshfs & pid=$!; "
                    + "while [ ! -e \"\(marker)\" ]; do sleep 0.05; done; kill -TERM $pid; wait $pid", script,
            ],
            env: [
                "COLIMABAR_PROFILE": "work", "COLIMABAR_APP": "1",
                "STUB_DELETE_DIR": "\(sb.home)/.config/colima/work",
            ])
        #expect(r.status == 143, "\(r.out)")
        let new = try #require(yaml(sb))
        #expect(new.contains("vmType: qemu\n") && new.contains("mountType: sshfs\n"))
        #expect(
            notices((r.status, r.out)).contains {
                $0.hasPrefix(
                    "The VM type change of profile 'work' did not finish. ColimaBar put colima.yaml back with the new values."
                )
            })
        #expect(sb.leavesNoLockOrBusyMarker)
    }

    // MARK: Lock and folders

    @Test func aStartInProgressRefusesBeforeTheDialog() async throws {
        let sb = try sandbox()
        try sb.write("start-command", "colima start --profile work")
        try sb.stub(
            "pgrep",
            """
            [ "$1" = -U ] && [ "$2" = "$(id -u)" ] && [ "$3" = -f ] || exit 1
            echo 4242
            """)
        try sb.stub("ps", "[ \"$*\" = '-o command= -p 4242' ] && cat '\(sb.home)/start-command'")
        let r = try await recreate(sb)
        #expect(r.status == 1)
        #expect(notices(r).first?.hasPrefix("A start of profile 'work' runs now.") == true)
        #expect(dialogs(sb).isEmpty)
        #expect(vmCalls(sb).isEmpty)
        #expect(yaml(sb) == config)
    }

    @Test func anotherActionHoldingTheLockExitsWithTwo() async throws {
        let sb = try sandbox()
        try sb.write("\(state)/lock.work/pid", "300\n")
        try sb.stubProcesses([.init(pid: 300, age: 4 * 3600, command: "bash /x/colima-ctl.sh restart")])
        try sb.setAge(sb.home + "/" + state + "/lock.work/pid", seconds: 120)
        try sb.setAge(sb.home + "/" + state + "/lock.work", seconds: 120)
        let r = try await recreate(sb)
        #expect(r.status == 2)
        #expect(vmCalls(sb).isEmpty)
    }

    @Test(arguments: [".colima", ".config/colima", "colima-home"])
    func theActionUsesTheColimaFolderThatExists(folder: String) async throws {
        let sb = try ScriptSandbox()
        try sb.stub("qemu-img", "exit 0")
        try sb.stub("qemu-system-aarch64", "exit 0")
        try sb.write("\(folder)/work/colima.yaml", config)
        var env = ["STUB_DELETE_DIR": "\(sb.home)/\(folder)/work"]
        if folder == "colima-home" { env["COLIMA_HOME"] = sb.home + "/colima-home" }
        let r = try await sb.ctl(["vm-recreate", "qemu", "sshfs"], env: env)
        #expect(r.status == 0, "\(r.out)")
        #expect(try #require(yaml(sb, "\(folder)/work/colima.yaml")).contains("vmType: qemu\n"))
    }

    // MARK: profile-create

    @Test func createPassesTheVMTypeAndTheMountType() async throws {
        let sb = try ScriptSandbox()
        try sb.stub("qemu-img", "exit 0")
        try sb.stub("qemu-system-aarch64", "exit 0")
        let r = try await sb.ctl(["profile-create", "4", "8", "60", "docker", "qemu", "9p"])
        #expect(r.status == 0, "\(r.out)")
        #expect(
            sb.calls.contains(
                "colima start --cpu 4 --memory 8 --disk 60 --runtime docker --vm-type qemu --mount-type 9p --profile work"
            ))
    }

    @Test func createWithoutTypesPassesNoTypeFlags() async throws {
        let sb = try ScriptSandbox()
        _ = try await sb.ctl(["profile-create", "4", "8", "60", "docker"])
        #expect(sb.calls.contains("colima start --cpu 4 --memory 8 --disk 60 --runtime docker --profile work"))
    }

    @Test(arguments: [["vz", "9p"], ["qemu", "virtiofs"], ["krunkit", "sshfs"], ["vz", ""]])
    func createRefusesABadPair(pair: [String]) async throws {
        let sb = try ScriptSandbox()
        let r = try await sb.ctl(["profile-create", "2", "2", "60", "docker", pair[0], pair[1]])
        #expect(r.status == 1)
        #expect(notices(r).first?.hasPrefix("Invalid VM type or mount type:") == true)
        #expect(!sb.calls.contains { $0.hasPrefix("colima start") })
    }

    @Test func createWithQEMUNeedsQEMU() async throws {
        let sb = try ScriptSandbox()
        let r = try await withoutHomebrew(sb, ["profile-create", "2", "2", "60", "docker", "qemu", "sshfs"])
        #expect(r.status == 1)
        #expect(notices(r).first?.hasPrefix("The qemu VM type needs QEMU.") == true)
        #expect(!sb.calls.contains { $0.hasPrefix("colima start") })
    }
}
