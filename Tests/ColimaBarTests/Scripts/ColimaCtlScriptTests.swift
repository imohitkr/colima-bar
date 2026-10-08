import Foundation
import Testing

@testable import ColimaBar

/// Runs scripts/colima-ctl.sh with stub `osascript`, `colima` and `docker`
/// (see ScriptSandbox). No dialog reaches the screen, and no VM changes.
@Suite struct ColimaCtlScriptTests {
    private func run(
        _ sandbox: ScriptSandbox, _ args: [String], profile: String = "work", env: [String: String] = [:]
    ) async throws -> (status: Int32, out: String) {
        let script = try sandbox.copy("colima-ctl.sh")
        return try await sandbox.bash(
            [script] + args, env: ["COLIMABAR_PROFILE": profile, "COLIMABAR_APP": "1"].merging(env) { $1 })
    }

    /// The text of the dialogs that the stub osascript got.
    private func dialogs(_ sandbox: ScriptSandbox) -> String {
        sandbox.calls.filter { !$0.hasPrefix("colima ") && !$0.hasPrefix("docker ") }.joined(separator: "\n")
    }

    private let config = "cpu: 2\ndisk: 100\nmemory: 2\nrosetta: false\nkubernetes:\n  enabled: false\n"

    @Test func createRunsColimaStartWithTheFormValues() async throws {
        let sb = try ScriptSandbox()
        let r = try await run(sb, ["profile-create", "4", "8", "60", "docker"])
        #expect(r.status == 0)
        #expect(sb.calls.contains("colima start --cpu 4 --memory 8 --disk 60 --runtime docker --profile work"))
        #expect(!sb.calls.contains { $0.hasPrefix("osascript") })  // the app's form was the confirmation
    }

    @Test func createUsesTheSameNameRulesAsTheApp() async throws {
        let bad = [
            "Work", "a_b", "-a", "a-", "a--b", "colima", "colima-x", "default", String(repeating: "a", count: 31),
        ]
        let good = ["work", "k8s-dev", String(repeating: "a", count: 30)]
        for name in bad {
            #expect(ProfileName.problem(newName: name, existing: []) != nil, "\(name)")
            let sb = try ScriptSandbox()
            let r = try await run(sb, ["profile-create", "2", "2", "60"], profile: name)
            #expect(r.status == 1, "\(name)")
            #expect(r.out.contains("COLIMABAR_NOTIFY:Invalid profile name"), "\(name)")
            #expect(!sb.calls.contains { $0.hasPrefix("colima start") }, "\(name)")
        }
        for name in good {
            #expect(ProfileName.problem(newName: name, existing: []) == nil, "\(name)")
            let sb = try ScriptSandbox()
            #expect(try await run(sb, ["profile-create", "2", "2", "60"], profile: name).status == 0, "\(name)")
        }
    }

    @Test func createRefusesAnExistingProfileAndBadValues() async throws {
        let sb = try ScriptSandbox()
        try sb.write(".config/colima/work/colima.yaml", config)
        #expect(try await run(sb, ["profile-create", "2", "2", "60"]).status == 1)
        #expect(try await run(sb, ["profile-create", "2", "2", "5"], profile: "new").status == 1)
        #expect(try await run(sb, ["profile-create", "x", "2", "60"], profile: "new").status == 1)
        #expect(try await run(sb, ["profile-create", "2", "2", "60", "incus"], profile: "new").status == 1)
        #expect(!sb.calls.contains { $0.hasPrefix("colima start") })
    }

    @Test func deleteAsksWithTheProfileNameThenDeletes() async throws {
        let sb = try ScriptSandbox()
        try sb.write(".config/colima/work/colima.yaml", config)
        let r = try await run(sb, ["profile-delete"])
        #expect(r.status == 0)
        #expect(dialogs(sb).contains("Delete profile 'work'? Colima deletes its VM and disk."))
        #expect(!dialogs(sb).contains("main Colima profile"))
        #expect(sb.calls.contains("colima delete --data --force --profile work"))
    }

    @Test func aCancelledDeleteDeletesNothing() async throws {
        let sb = try ScriptSandbox()
        try sb.write(".config/colima/work/colima.yaml", config)
        let r = try await run(sb, ["profile-delete"], env: ["STUB_OSASCRIPT_EXIT": "1"])
        #expect(r.status == 2)
        #expect(dialogs(sb).contains("Delete profile 'work'?"))  // the stub got the dialog
        #expect(!sb.calls.contains { $0.hasPrefix("colima delete") })
    }

    @Test func deletingDefaultWarnsMore() async throws {
        let sb = try ScriptSandbox()
        try sb.write(".config/colima/default/colima.yaml", config)
        #expect(try await run(sb, ["profile-delete"], profile: "default").status == 0)
        #expect(dialogs(sb).contains("'default' is the main Colima profile."))
    }

    @Test(arguments: ["colima", "colima-work", "colima-"])
    func deleteRefusesNamesThatColimaReadsAsAnotherProfile(name: String) async throws {
        // Colima maps "colima" to "default" and reads "colima-work" as "work".
        let sb = try ScriptSandbox()
        try sb.write(".config/colima/default/colima.yaml", config)
        try sb.write(".config/colima/work/colima.yaml", config)
        try sb.write(".config/colima/\(name)/colima.yaml", config)
        let r = try await run(sb, ["profile-delete"], profile: name)
        #expect(r.status == 1)
        #expect(
            r.out.contains(
                "COLIMABAR_NOTIFY:Can't delete profile '\(name)'. Colima reads this name as a different profile."))
        #expect(sb.calls.isEmpty)  // no dialog, no colima call
    }

    @Test func deleteRefusesAProfileWithoutAFolder() async throws {
        let sb = try ScriptSandbox()
        try sb.write(".config/colima/default/colima.yaml", config)
        for name in ["work", "Default"] {  // "Default" finds "default" on a case-insensitive disk
            let r = try await run(sb, ["profile-delete"], profile: name)
            #expect(r.status == 1, "\(name)")
            #expect(r.out.contains("COLIMABAR_NOTIFY:Can't delete profile '\(name)'. Its folder"), "\(name)")
        }
        #expect(sb.calls.isEmpty)
    }

    @Test(arguments: ["Work", "wörk", "é", "Ａb"])
    func nameChecksRejectNonASCIIAndUppercaseInEveryLocale(name: String) async throws {
        for locale in ["en_US.UTF-8", "de_DE.UTF-8", "C"] {
            let sb = try ScriptSandbox()
            let r = try await run(
                sb, ["profile-create", "2", "2", "60"], profile: name, env: ["LANG": locale, "LC_ALL": locale])
            #expect(r.status == 1, "\(name) \(locale)")
            #expect(!sb.calls.contains { $0.hasPrefix("colima start") }, "\(name) \(locale)")
        }
    }

    /// Runs disk-shrink 50 for a colima.yaml in `dir` (relative to HOME), with
    /// a stub `colima delete` that removes the profile folder.
    private func shrink(
        _ sb: ScriptSandbox, configIn dir: String, text: String? = nil, env: [String: String] = [:]
    ) async throws -> (status: Int32, out: String) {
        try sb.write("\(dir)/work/colima.yaml", text ?? config)
        return try await run(
            sb, ["disk-shrink", "50"], env: ["STUB_DELETE_DIR": "\(sb.home)/\(dir)/work"].merging(env) { $1 })
    }

    private func disk(_ sb: ScriptSandbox, _ dir: String) -> String? {
        let text = try? String(contentsOfFile: "\(sb.home)/\(dir)/work/colima.yaml", encoding: .utf8)
        return text?.split(separator: "\n").first { $0.hasPrefix("disk:") }.map(String.init)
    }

    @Test func diskShrinkUsesTheConfigFolderWhenItExists() async throws {
        let sb = try ScriptSandbox()
        #expect(try await shrink(sb, configIn: ".config/colima").status == 0)
        #expect(disk(sb, ".config/colima") == "disk: 50")
        #expect(!FileManager.default.fileExists(atPath: sb.home + "/.colima"))
    }

    @Test func diskShrinkUsesDotColimaWhenItExists() async throws {
        // ~/.colima wins over ~/.config/colima.
        let sb = try ScriptSandbox()
        try sb.write(".config/colima/work/colima.yaml", "cpu: 2\ndisk: 200\n")
        #expect(try await shrink(sb, configIn: ".colima").status == 0)
        #expect(disk(sb, ".colima") == "disk: 50")
        #expect(disk(sb, ".config/colima") == "disk: 200")  // the unused copy stays
    }

    @Test func diskShrinkUsesColimaHomeWhenItExists() async throws {
        let sb = try ScriptSandbox()
        try sb.write(".colima/work/colima.yaml", "cpu: 2\ndisk: 200\n")
        #expect(
            try await shrink(sb, configIn: "colima-home", env: ["COLIMA_HOME": sb.home + "/colima-home"]).status == 0)
        #expect(disk(sb, "colima-home") == "disk: 50")
        #expect(disk(sb, ".colima") == "disk: 200")
    }

    @Test func aMissingColimaHomeIsIgnored() async throws {
        // Colima ignores COLIMA_HOME when that path does not exist.
        let sb = try ScriptSandbox()
        let r = try await shrink(sb, configIn: ".config/colima", env: ["COLIMA_HOME": sb.home + "/missing"])
        #expect(r.status == 0)
        #expect(disk(sb, ".config/colima") == "disk: 50")
        #expect(!FileManager.default.fileExists(atPath: sb.home + "/missing"))
    }

    /// A stub `colima` that also logs the COLIMA_HOME it gets.
    private func stubColimaHome(_ sb: ScriptSandbox) throws {
        try sb.stub(
            "colima",
            """
            printf 'colima %s COLIMA_HOME=%s\\n' "$*" "${COLIMA_HOME:-}" >> "\(sb.log)"
            [ "$1" = status ] && exit 1
            exit 0
            """)
    }

    @Test(arguments: [["start"], ["ssh"]])
    func colimaCallsGetTheColimaFolderInColimaHome(args: [String]) async throws {
        // A new Mac: no folder exists. ~/.colima is made first, because
        // Colima skips a COLIMA_HOME that does not exist.
        let sb = try ScriptSandbox()
        try stubColimaHome(sb)
        #expect(try await run(sb, args).status == 0)
        let call = try #require(sb.calls.first { $0.hasPrefix("colima ") })
        #expect(call.hasSuffix("--profile work COLIMA_HOME=\(sb.home)/.colima"))
        #expect(FileManager.default.fileExists(atPath: sb.home + "/.colima"))
        #expect(!FileManager.default.fileExists(atPath: sb.home + "/.config/colima"))
    }

    @Test func colimaCallsUseTheConfigFolderWhenOnlyItExists() async throws {
        // Without XDG_CONFIG_HOME, Colima would pick ~/.colima here. COLIMA_HOME keeps the
        // VM of an older ColimaBar version in ~/.config/colima.
        let sb = try ScriptSandbox()
        try stubColimaHome(sb)
        try sb.write(".config/colima/work/colima.yaml", config)
        #expect(try await run(sb, ["start"], env: ["XDG_CONFIG_HOME": sb.home + "/xdg"]).status == 0)
        #expect(sb.calls.contains("colima start --profile work COLIMA_HOME=\(sb.home)/.config/colima"))
        #expect(!FileManager.default.fileExists(atPath: sb.home + "/.colima"))
    }

    @Test func xdgConfigHomeCountsOnlyWhenNoFolderExists() async throws {
        let sb = try ScriptSandbox()
        try stubColimaHome(sb)
        #expect(try await run(sb, ["start"], env: ["XDG_CONFIG_HOME": sb.home + "/xdg"]).status == 0)
        #expect(sb.calls.contains("colima start --profile work COLIMA_HOME=\(sb.home)/xdg/colima"))
        #expect(FileManager.default.fileExists(atPath: sb.home + "/xdg/colima"))
        #expect(!FileManager.default.fileExists(atPath: sb.home + "/.colima"))
    }

    @Test func aFolderChangeDuringAnActionStopsItAndCreatesNothing() async throws {
        // The action starts with ~/.colima. The user deletes it while the VM
        // stops. An empty new ~/.colima would hide ~/.config/colima from then on.
        let sb = try ScriptSandbox()
        try sb.stub(
            "colima",
            """
            printf 'colima %s COLIMA_HOME=%s\\n' "$*" "${COLIMA_HOME:-}" >> "\(sb.log)"
            [ "$1" = status ] && { rm -rf "\(sb.home)/.colima"; exit 0; }
            exit 0
            """)
        try sb.write(".colima/work/colima.yaml", config)
        try sb.write(".config/colima/work/colima.yaml", config)
        let result = try await run(sb, ["restart"])
        #expect(result.status != 0)
        #expect(!FileManager.default.fileExists(atPath: sb.home + "/.colima"))
        #expect(!sb.calls.contains { $0.hasPrefix("colima stop") || $0.hasPrefix("colima start") })
    }

    @Test func aFolderChangeTellsTheUserWhy() async throws {
        let sb = try ScriptSandbox()
        try sb.stub(
            "colima",
            """
            [ "$1" = status ] && { rm -rf "\(sb.home)/.colima"; exit 0; }
            exit 0
            """)
        try sb.write(".colima/work/colima.yaml", config)
        try sb.write(".config/colima/work/colima.yaml", config)
        // restart runs `colima status`, which deletes ~/.colima here, then `colima stop`.
        let result = try await run(sb, ["restart"])
        #expect(result.status == 1)
        // One notice with the reason, not also the general failure notice.
        let notices = result.out.split(separator: "\n").filter { $0.hasPrefix("COLIMABAR_NOTIFY:") }
        #expect(
            notices == ["COLIMABAR_NOTIFY:The Colima folder changed during the action of profile 'work'. Try again."])
        let state = (try? FileManager.default.contentsOfDirectory(atPath: sb.home + "/.cache/colima-bar")) ?? []
        #expect(!state.contains { $0.hasPrefix("folder-changed.") })
    }

    @Test(arguments: [["resources", "2", "4"], ["k8s", "on"], ["disk", "200"]])
    func aFolderChangeBeforeTheFirstStatusCheckTellsTheUser(args: [String]) async throws {
        // The first `colima status` runs in the main shell, under a redirect.
        // The stub mkdir deletes ~/.colima when lock_vm takes the lock, before
        // that check. Bash 3.2 can keep a redirect while the EXIT trap runs,
        // so the status runs in a subshell, and the notice still reaches the app.
        let sb = try ScriptSandbox()
        try sb.stub(
            "mkdir",
            """
            case "$*" in *lock.work*) rm -rf "\(sb.home)/.colima" ;; esac
            exec /bin/mkdir "$@"
            """)
        try sb.write(".colima/work/colima.yaml", config)
        try sb.write(".config/colima/work/colima.yaml", config)
        let result = try await run(sb, args)
        #expect(result.status == 1)
        let notices = result.out.split(separator: "\n").filter { $0.hasPrefix("COLIMABAR_NOTIFY:") }
        #expect(
            notices == ["COLIMABAR_NOTIFY:The Colima folder changed during the action of profile 'work'. Try again."])
        let log = (try? String(contentsOfFile: sb.home + "/.cache/colima-bar/ctl.log", encoding: .utf8)) ?? ""
        #expect(log.contains("the Colima folder changed during the action"))
        #expect(!FileManager.default.fileExists(atPath: sb.home + "/.colima"))
        #expect(dialogs(sb).isEmpty)
        let state = (try? FileManager.default.contentsOfDirectory(atPath: sb.home + "/.cache/colima-bar")) ?? []
        #expect(!state.contains { $0.hasPrefix("folder-changed.") })
    }

    @Test func aFolderChangeDuringAShrinkNamesTheBackup() async throws {
        // The VM runs. `colima stop` deletes ~/.colima after the backup exists.
        let sb = try ScriptSandbox()
        try sb.stub(
            "colima",
            """
            [ "$1" = stop ] && rm -rf "\(sb.home)/.colima"
            exit 0
            """)
        try sb.write(".config/colima/work/colima.yaml", config)
        let result = try await shrink(sb, configIn: ".colima")
        #expect(result.status == 1)
        let backup = sb.home + "/.cache/colima-bar/colima.work.yaml.shrink"
        #expect(result.out.contains("Try again. A copy of colima.yaml is in \(backup)."))
        #expect(FileManager.default.fileExists(atPath: backup))
        #expect(!FileManager.default.fileExists(atPath: sb.home + "/.colima"))
    }

    @Test func aMarkerOfAnEarlierScriptWithTheSamePIDIsIgnored() async throws {
        let sb = try ScriptSandbox()
        try sb.write(".config/colima/work/colima.yaml", config)
        let script = try sb.copy("colima-ctl.sh")
        // exec keeps the PID, so the script sees a marker with its own PID.
        let result = try await sb.bash(
            [
                "-c",
                "mkdir -p \"$HOME/.cache/colima-bar\" && touch \"$HOME/.cache/colima-bar/folder-changed.$$\" "
                    + "&& exec /bin/bash \"$0\" stop", script,
            ],
            env: ["COLIMABAR_PROFILE": "work", "COLIMABAR_APP": "1"])
        #expect(result.status == 0)
        #expect(!result.out.contains("COLIMABAR_NOTIFY:"))
    }

    @Test func nothingIsCreatedWhenColimaIsNotInstalled() async throws {
        let sb = try ScriptSandbox()
        // A copy whose PATH has the stubs and the system folders only, and no colima.
        let script = try sb.copy("colima-ctl.sh")
        let text = try String(contentsOfFile: script, encoding: .utf8)
        let pathLine = try #require(text.split(separator: "\n").first { $0.hasPrefix("export PATH=") })
        try text.replacingOccurrences(
            of: String(pathLine), with: "export PATH=\"\(sb.bin):/usr/bin:/bin:/usr/sbin:/sbin\""
        ).write(toFile: script, atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(atPath: sb.bin + "/colima")
        _ = try await sb.bash([script, "start"], env: ["COLIMABAR_PROFILE": "work", "COLIMABAR_APP": "1"])
        #expect(!FileManager.default.fileExists(atPath: sb.home + "/.colima"))
    }

    @Test func theScriptKeepsTheLocale() throws {
        // A changed locale could garble non-ASCII text in dialogs. The name
        // checks use character lists, so they need no locale.
        let text = try String(
            contentsOf: ScriptSandbox.repo.appendingPathComponent("scripts/colima-ctl.sh"), encoding: .utf8)
        #expect(!text.contains("LC_ALL"))
        #expect(!text.contains("[!a-z") && !text.contains("[!A-Z") && !text.contains("[!0-9"))
    }

    @Test func deleteFindsTheProfileInDotColima() async throws {
        let sb = try ScriptSandbox()
        try sb.write(".colima/work/colima.yaml", config)
        #expect(try await run(sb, ["profile-delete"]).status == 0)
        #expect(sb.calls.contains("colima delete --data --force --profile work"))
    }

    @Test(arguments: [
        (["resources", "4", "8"], "Restart the Colima VM of profile 'work' with 4 CPU / 8 GB RAM?"),
        (["rosetta", "on"], "Turn Rosetta (amd64 emulation) on for profile 'work'?"),
        (["k8s", "on"], "Turn Kubernetes (k3s) on for profile 'work'?"),
        (["disk", "120"], "Grow the Colima disk of profile 'work' to 120 GB?"),
        (["disk-shrink", "50"], "Delete all Docker data of profile 'work' and shrink its disk from 100 GB to 50 GB?"),
        (["prune", "dangling"], "Remove dangling images and build cache of profile 'work'?"),
        (["prune", "all"], "Full cleanup of profile 'work':"),
    ])
    func vmDialogsNameTheProfile(args: [String], text: String) async throws {
        let sb = try ScriptSandbox()
        try sb.write(".config/colima/work/colima.yaml", config)
        // A running VM: a stopped one saves some settings with no dialog.
        let r = try await run(sb, args, env: ["STUB_COLIMA_STATUS": "0"])
        #expect(r.status == 0, "\(r.out)")
        #expect(dialogs(sb).contains(text))
    }

    @Test func restartStopsAndStartsARunningVM() async throws {
        // bash 3.2 must not end the action after its first colima call (see with_busy).
        let sb = try ScriptSandbox()
        #expect(try await run(sb, ["restart"], env: ["STUB_COLIMA_STATUS": "0"]).status == 0)
        #expect(
            sb.calls == ["colima status --profile work", "colima stop --profile work", "colima start --profile work"])
    }

    @Test func failuresNameTheProfile() async throws {
        let sb = try ScriptSandbox()
        try sb.stub("colima", "exit 1")
        let r = try await run(sb, ["start"])
        #expect(r.status == 1)
        #expect(r.out.contains("COLIMABAR_NOTIFY:Start of profile 'work' failed"))
    }

    // MARK: - Settings of a stopped VM

    private let yamlPath = ".config/colima/work/colima.yaml"

    /// The colima.yaml of the profile "work" in the sandbox.
    private func yaml(_ sb: ScriptSandbox) -> String {
        (try? String(contentsOfFile: "\(sb.home)/\(yamlPath)", encoding: .utf8)) ?? ""
    }

    /// The colima calls other than `colima status`.
    private func vmCalls(_ sb: ScriptSandbox) -> [String] {
        sb.calls.filter { $0.hasPrefix("colima ") && !$0.hasPrefix("colima status") }
    }

    @Test(arguments: [
        (["resources", "4", "8"], ["cpu: 4", "memory: 8"]),
        (["rosetta", "on"], ["rosetta: true"]),
        (["k8s", "on"], ["  enabled: true"]),
    ])
    func aStoppedVMSavesSettingsWithNoDialogAndNoStart(args: [String], lines: [String]) async throws {
        let sb = try ScriptSandbox()
        try sb.write(yamlPath, config)
        let r = try await run(sb, args, env: ["COLIMABAR_EXPECT_RUNNING": "0"])
        #expect(r.status == 0)
        #expect(!r.out.contains("COLIMABAR_NOTIFY:"))
        let file = yaml(sb).split(separator: "\n").map(String.init)
        for line in lines { #expect(file.contains(line), "\(line)") }
        #expect(!sb.calls.contains { $0.hasPrefix("osascript") })
        #expect(vmCalls(sb).isEmpty)  // no start, no stop
        #expect(!FileManager.default.fileExists(atPath: sb.home + "/.cache/colima-bar/busy.work"))
    }

    @Test func kubernetesOnForAStoppedVMRunsNoKubectl() async throws {
        // The context does not exist before the first start with Kubernetes.
        let sb = try ScriptSandbox()
        try sb.write(yamlPath, config)
        #expect(try await run(sb, ["k8s", "on"]).status == 0)
        #expect(!sb.calls.contains { $0.hasPrefix("kubectl") })
    }

    @Test func aRunningVMStillAsksThenRestarts() async throws {
        let sb = try ScriptSandbox()
        try sb.write(yamlPath, config)
        let r = try await run(
            sb, ["resources", "4", "8"], env: ["STUB_COLIMA_STATUS": "0", "COLIMABAR_EXPECT_RUNNING": "1"])
        #expect(r.status == 0)
        #expect(dialogs(sb).contains("Restart the Colima VM of profile 'work' with 4 CPU / 8 GB RAM?"))
        #expect(vmCalls(sb) == ["colima stop --profile work", "colima start --profile work"])
        #expect(yaml(sb).contains("cpu: 4\n"))
    }

    @Test(arguments: ["2.5", "1", "1.25", "16"])
    func resourcesSavesAWholeOrDecimalMemory(memory: String) async throws {
        // Colima reads the memory as GiB: `memory: 2.5` runs with 2.5 GiB.
        let sb = try ScriptSandbox()
        try sb.write(yamlPath, config)
        let r = try await run(sb, ["resources", "4", memory], env: ["COLIMABAR_EXPECT_RUNNING": "0"])
        #expect(r.status == 0, "\(r.out)")
        let file = yaml(sb).split(separator: "\n").map(String.init)
        #expect(file.contains("cpu: 4"))
        #expect(file.contains("memory: \(memory)"))
        #expect(VMConfig.parse(yaml(sb)).memGB == Double(memory))
    }

    @Test(arguments: [
        ("4", "0"), ("4", "0.5"), ("4", "00.9"), ("4", ".5"), ("4", "2."), ("4", "1.2.3"), ("4", "-2"), ("4", "2,5"),
        ("4", ""), ("0", "4"), ("2.5", "4"), ("x", "4"),
        // Numbers too long for the checks of the script.
        ("12345", "4"), ("4", "1234567"), ("99999999999999999999", "4"),
    ])
    func resourcesRefusesABadValue(cpu: String, memory: String) async throws {
        let sb = try ScriptSandbox()
        try sb.write(yamlPath, config)
        let r = try await run(sb, ["resources", cpu, memory], env: ["COLIMABAR_EXPECT_RUNNING": "0"])
        #expect(r.status == 1)
        #expect(
            r.out.contains(
                "COLIMABAR_NOTIFY:Invalid CPU/memory for profile 'work': \(cpu) / \(memory). Use at least 1 CPU and 1 GB of memory."
            ))
        #expect(yaml(sb) == config)
        #expect(sb.calls.isEmpty)
    }

    @Test func aStoppedDiskGrowAsksThenSavesTheSize() async throws {
        let sb = try ScriptSandbox()
        try sb.write(yamlPath, config)
        let r = try await run(sb, ["disk", "200"])
        #expect(r.status == 0)
        let text = dialogs(sb)
        #expect(text.contains("Set the disk of profile 'work' to 200 GB?"))
        #expect(text.contains("Colima grows the disk at the next start."))
        #expect(yaml(sb).contains("disk: 200\n"))
        #expect(vmCalls(sb).isEmpty)
    }

    @Test func aCancelledStoppedDiskGrowChangesNothing() async throws {
        let sb = try ScriptSandbox()
        try sb.write(yamlPath, config)
        let r = try await run(sb, ["disk", "200"], env: ["STUB_OSASCRIPT_EXIT": "1"])
        #expect(r.status == 2)
        #expect(dialogs(sb).contains("Set the disk of profile 'work' to 200 GB?"))
        #expect(yaml(sb) == config)
    }

    /// The VM started or stopped while a dialog was open.
    private let dialogStateNotice =
        "COLIMABAR_NOTIFY:The VM of profile 'work' started or stopped while the dialog was open. Nothing changed. Try again."

    @Test func aStateChangeDuringTheDiskDialogChangesNothing() async throws {
        // The VM starts while the dialog is open.
        let sb = try ScriptSandbox()
        let started = sb.root + "/started"
        try sb.stub(
            "osascript",
            """
            printf 'osascript %s\\n' "$*" >> "\(sb.log)"
            touch "\(started)"
            exit 0
            """)
        try sb.stub(
            "colima",
            """
            printf 'colima %s\\n' "$*" >> "\(sb.log)"
            [ "$1" = status ] && { [ -e "\(started)" ] && exit 0; exit 1; }
            exit 0
            """)
        try sb.write(yamlPath, config)
        let r = try await run(sb, ["disk", "200"])
        #expect(r.status == 1)
        #expect(r.out.contains(dialogStateNotice))
        #expect(yaml(sb) == config)
        #expect(vmCalls(sb).isEmpty)
    }

    /// The VM is not in the state that the app sent. No dialog was open.
    private let stateNotice =
        "COLIMABAR_NOTIFY:The VM of profile 'work' started or stopped. Nothing changed. Try again."

    private let startNotice = "COLIMABAR_NOTIFY:A start of profile 'work' runs now. Try again when it ends."

    @Test(arguments: [
        (["resources", "4", "8"], "0", "0"), (["rosetta", "on"], "0", "0"), (["k8s", "on"], "0", "0"),
        (["resources", "4", "8"], "1", "1"), (["rosetta", "on"], "1", "1"), (["k8s", "on"], "1", "1"),
    ])
    func aStateThatDiffersFromTheExpectedStateChangesNothing(args: [String], expect: String, status: String)
        async throws
    {
        // The app expects the other state: the VM started or stopped outside
        // the app. A dialog would open behind the popover.
        let sb = try ScriptSandbox()
        try sb.write(yamlPath, config)
        let r = try await run(sb, args, env: ["COLIMABAR_EXPECT_RUNNING": expect, "STUB_COLIMA_STATUS": status])
        #expect(r.status == 1)
        #expect(r.out.split(separator: "\n").map(String.init) == [stateNotice])
        #expect(dialogs(sb).isEmpty)
        #expect(yaml(sb) == config)
        #expect(vmCalls(sb).isEmpty)
    }

    /// A stub `pgrep` that finds one process of this user when its `-f`
    /// pattern matches `command`, and a stub `ps` that prints `command` as
    /// the command line of that process.
    private func stubStartProcess(_ sb: ScriptSandbox, command: String) throws {
        try sb.write("start-command", command)
        try sb.stub(
            "pgrep",
            """
            [ "$1" = -U ] && [ "$2" = "$(id -u)" ] && [ "$3" = -f ] || exit 1
            /usr/bin/grep -qE -- "$4" "\(sb.home)/start-command" && { echo 4242; exit 0; }
            exit 1
            """)
        try sb.stub("ps", "[ \"$*\" = '-o command= -p 4242' ] && cat '\(sb.home)/start-command'")
    }

    @Test(arguments: [
        ("/opt/homebrew/bin/colima start --profile work", true),
        ("colima restart -p work", true),
        ("colima restart -f work", true),
        ("colima start work", true),
        ("colima start --profile=work --cpu 4", true),
        ("colima start -p=work", true),
        ("colima start --cpu 4 work", true),
        ("colima start -c 4 work", true),
        ("colima start --memory 2.5 --mount-type virtiofs work", true),
        ("colima start --kubernetes work", true),
        ("colima start colima-work", true),
        ("colima start --profile colima-work", true),
        ("colima start -f --profile work", false),
        ("colima start --foreground work", false),
        ("colima start --profile other", false),
        ("colima start --cpu 4 other", false),
        ("colima start work --profile other", false),
        ("colima start", false),
        ("colima start colima", false),
        ("colima status work", false),
    ])
    func aColimaStartInProgressRefusesTheChange(command: String, counts: Bool) async throws {
        // `colima status` still fails while the VM starts.
        let sb = try ScriptSandbox()
        try stubStartProcess(sb, command: command)
        try sb.write(yamlPath, config)
        let r = try await run(sb, ["rosetta", "on"], env: ["COLIMABAR_EXPECT_RUNNING": "0"])
        #expect(ColimaModel.isStartInProgress(command: command, profile: "work") == counts)
        if counts {
            #expect(r.status == 1)
            #expect(r.out.split(separator: "\n").map(String.init) == [startNotice])
            #expect(yaml(sb) == config)
        } else {
            #expect(r.status == 0)
            #expect(yaml(sb).contains("rosetta: true\n"))
        }
        #expect(dialogs(sb).isEmpty)
    }

    @Test func colimaStartMeansTheDefaultProfile() async throws {
        let sb = try ScriptSandbox()
        try stubStartProcess(sb, command: "colima start colima")
        try sb.write(".config/colima/default/colima.yaml", config)
        let r = try await run(sb, ["rosetta", "on"], profile: "default", env: ["COLIMABAR_EXPECT_RUNNING": "0"])
        #expect(r.status == 1)
        #expect(r.out.contains("COLIMABAR_NOTIFY:A start of profile 'default' runs now."))
    }

    @Test(arguments: [
        (["resources", "4", "8"], "1"), (["rosetta", "on"], "1"), (["k8s", "on"], "1"), (["disk", "200"], ""),
        (["disk-shrink", "50"], ""),
    ])
    func aRunningVMWithAStartInProgressRefusesBeforeAnyDialog(args: [String], expect: String) async throws {
        // `colima status` succeeds, and a `colima restart` runs in a terminal.
        // A restart or a shrink now would run a second start, or delete the VM.
        let sb = try ScriptSandbox()
        try stubStartProcess(sb, command: "colima restart --profile work")
        try sb.write(yamlPath, config)
        var env = ["STUB_COLIMA_STATUS": "0"]
        if !expect.isEmpty { env["COLIMABAR_EXPECT_RUNNING"] = expect }
        let r = try await run(sb, args, env: env)
        #expect(r.status == 1)
        #expect(r.out.split(separator: "\n").map(String.init) == [startNotice])
        #expect(dialogs(sb).isEmpty)
        #expect(vmCalls(sb).isEmpty)
        #expect(yaml(sb) == config)
    }

    @Test(arguments: [["disk", "200"], ["disk-shrink", "50"]])
    func aStoppedVMWithAStartInProgressRefusesADiskChange(args: [String]) async throws {
        let sb = try ScriptSandbox()
        try stubStartProcess(sb, command: "colima start work")
        try sb.write(yamlPath, config)
        let r = try await run(sb, args)
        #expect(r.status == 1)
        #expect(r.out.split(separator: "\n").map(String.init) == [startNotice])
        #expect(dialogs(sb).isEmpty)
        #expect(vmCalls(sb).isEmpty)
        #expect(yaml(sb) == config)
    }

    @Test func aStateChangeDuringTheShrinkDialogDeletesNothing() async throws {
        // The VM is stopped, and it starts while the dialog is open.
        let sb = try ScriptSandbox()
        let started = sb.root + "/started"
        try sb.stub(
            "osascript",
            """
            printf 'osascript %s\\n' "$*" >> "\(sb.log)"
            touch "\(started)"
            exit 0
            """)
        try sb.stub(
            "colima",
            """
            printf 'colima %s\\n' "$*" >> "\(sb.log)"
            [ "$1" = status ] && { [ -e "\(started)" ] && exit 0; exit 1; }
            [ "$1" = delete ] && rm -rf "$STUB_DELETE_DIR"
            exit 0
            """)
        let r = try await shrink(sb, configIn: ".config/colima")
        #expect(r.status == 1)
        #expect(r.out.contains(dialogStateNotice))
        #expect(dialogs(sb).contains("Delete all Docker data of profile 'work'"))
        #expect(vmCalls(sb).isEmpty)  // no stop, no delete, no start
        #expect(yaml(sb) == config)
        #expect(!FileManager.default.fileExists(atPath: sb.home + "/.cache/colima-bar/colima.work.yaml.shrink"))
    }

    @Test(arguments: ["disk: 100 # GiB", "disk: \"100\"", "disk: '100' # GiB", "disk: 100.0", "disk:100"])
    func diskShrinkReadsTheSameDiskFormsAsTheApp(line: String) async throws {
        let text = config.replacingOccurrences(of: "disk: 100", with: line)
        #expect(VMConfig.parse(text).diskGB == 100)
        let sb = try ScriptSandbox()
        let r = try await shrink(sb, configIn: ".config/colima", text: text)
        #expect(r.status == 0, "\(r.out)")
        #expect(dialogs(sb).contains("shrink its disk from 100 GB to 50 GB?"))
        #expect(yaml(sb) == config.replacingOccurrences(of: "disk: 100", with: "disk: 50"))
    }

    @Test func diskShrinkReadsACRLFFile() async throws {
        let text = config.replacingOccurrences(of: "\n", with: "\r\n")
        #expect(VMConfig.parse(text).diskGB == 100)
        #expect(VMConfig.parse(text).kubernetes == false)
        let sb = try ScriptSandbox()
        let r = try await shrink(
            sb, configIn: ".config/colima", text: text.replacingOccurrences(of: "false", with: "true"))
        #expect(r.status == 0, "\(r.out)")
        let said = dialogs(sb)
        #expect(said.contains("shrink its disk from 100 GB to 50 GB?"))
        #expect(said.contains("The Kubernetes cluster and its data are also deleted."))
        #expect(yaml(sb).contains("disk: 50\n"))
    }

    @Test func kubernetesOnWithLittleMemoryNotesTheMemoryUse() async throws {
        let sb = try ScriptSandbox()
        try sb.write(yamlPath, config)  // memory: 2
        #expect(try await run(sb, ["k8s", "on"], env: ["STUB_COLIMA_STATUS": "0"]).status == 0)
        #expect(dialogs(sb).contains("The VM has 2 GB of memory. Kubernetes uses about 0.5 to 1 GB of it."))
        #expect(sb.calls.contains("kubectl config use-context colima-work"))

        let big = try ScriptSandbox()
        try big.write(yamlPath, config.replacingOccurrences(of: "memory: 2", with: "memory: 8"))
        #expect(try await run(big, ["k8s", "on"], env: ["STUB_COLIMA_STATUS": "0"]).status == 0)
        #expect(dialogs(big).contains("Turn Kubernetes (k3s) on"))
        #expect(!dialogs(big).contains("GB of memory"))
    }

    @Test(arguments: ["2.5", "0.5", "\"3\" # GiB"])
    func theMemoryNoteShowsTheValueOfColimaYAML(memory: String) async throws {
        let sb = try ScriptSandbox()
        try sb.write(yamlPath, config.replacingOccurrences(of: "memory: 2", with: "memory: \(memory)"))
        #expect(try await run(sb, ["k8s", "on"], env: ["STUB_COLIMA_STATUS": "0"]).status == 0)
        let shown = memory.hasPrefix("\"") ? "3" : memory
        #expect(dialogs(sb).contains("The VM has \(shown) GB of memory."))
    }

    @Test func kubernetesOffShowsNoMemoryNote() async throws {
        let sb = try ScriptSandbox()
        try sb.write(yamlPath, config)  // memory: 2
        #expect(try await run(sb, ["k8s", "off"], env: ["STUB_COLIMA_STATUS": "0"]).status == 0)
        #expect(dialogs(sb).contains("Turn Kubernetes (k3s) off"))
        #expect(!dialogs(sb).contains("GB of memory"))
    }

    @Test func aStoppedShrinkStartsOnceThenStopsAgain() async throws {
        let sb = try ScriptSandbox()
        let r = try await shrink(sb, configIn: ".config/colima")
        #expect(r.status == 0)
        #expect(dialogs(sb).contains("Colima starts the VM once to create the new 50 GB disk, then stops it again."))
        #expect(
            vmCalls(sb) == [
                "colima delete --data --force --profile work", "colima start --profile work",
                "colima stop --profile work",
            ])
        // The other settings come back with the new size.
        #expect(yaml(sb) == config.replacingOccurrences(of: "disk: 100", with: "disk: 50"))
        #expect(!FileManager.default.fileExists(atPath: sb.home + "/.cache/colima-bar/colima.work.yaml.shrink"))
    }

    @Test func aRunningShrinkDoesNotStopAtTheEnd() async throws {
        let sb = try ScriptSandbox()
        let r = try await shrink(sb, configIn: ".config/colima", env: ["STUB_COLIMA_STATUS": "0"])
        #expect(r.status == 0)
        #expect(dialogs(sb).contains("Then Colima starts the VM again with an empty 50 GB disk"))
        #expect(
            vmCalls(sb) == [
                "colima stop --profile work", "colima delete --data --force --profile work",
                "colima start --profile work",
            ])
        #expect(yaml(sb).contains("disk: 50\n"))
    }

    @Test func aFailedStopAfterAStoppedShrinkNamesTheNewSize() async throws {
        let sb = try ScriptSandbox()
        try sb.stub(
            "colima",
            """
            printf 'colima %s\\n' "$*" >> "\(sb.log)"
            [ "$1" = status ] && exit 1
            [ "$1" = delete ] && rm -rf "$STUB_DELETE_DIR"
            [ "$1" = stop ] && exit 1
            exit 0
            """)
        let r = try await shrink(sb, configIn: ".config/colima")
        #expect(r.status == 1)
        let notices = r.out.split(separator: "\n").filter { $0.hasPrefix("COLIMABAR_NOTIFY:") }
        #expect(notices.count == 1)
        #expect(
            notices.first?.hasPrefix("COLIMABAR_NOTIFY:The disk of profile 'work' is now 50 GB, but the stop failed")
                == true)
        #expect(yaml(sb).contains("disk: 50\n"))
        // The new colima.yaml is in place, so the copy is not needed.
        #expect(!FileManager.default.fileExists(atPath: sb.home + "/.cache/colima-bar/colima.work.yaml.shrink"))
    }
}
