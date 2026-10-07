import Foundation
import Testing

@testable import ColimaBar

/// Runs scripts/colima-ctl.sh with stub `osascript`, `colima` and `docker`
/// (see ScriptSandbox). No dialog reaches the screen, and no VM changes.
@Suite struct ColimaCtlScriptTests {
    private func run(
        _ sandbox: ScriptSandbox, _ args: [String], profile: String = "work", env: [String: String] = [:]
    ) throws -> (status: Int32, out: String) {
        let script = try sandbox.copy("colima-ctl.sh")
        return try sandbox.bash(
            [script] + args, env: ["COLIMABAR_PROFILE": profile, "COLIMABAR_APP": "1"].merging(env) { $1 })
    }

    /// The text of the dialogs that the stub osascript got.
    private func dialogs(_ sandbox: ScriptSandbox) -> String {
        sandbox.calls.filter { !$0.hasPrefix("colima ") && !$0.hasPrefix("docker ") }.joined(separator: "\n")
    }

    private let config = "cpu: 2\ndisk: 100\nmemory: 2\nrosetta: false\nkubernetes:\n  enabled: false\n"

    @Test func createRunsColimaStartWithTheFormValues() throws {
        let sb = try ScriptSandbox()
        let r = try run(sb, ["profile-create", "4", "8", "60", "docker"])
        #expect(r.status == 0)
        #expect(sb.calls.contains("colima start --cpu 4 --memory 8 --disk 60 --runtime docker --profile work"))
        #expect(!sb.calls.contains { $0.hasPrefix("osascript") })  // the app's form was the confirmation
    }

    @Test func createUsesTheSameNameRulesAsTheApp() throws {
        let bad = [
            "Work", "a_b", "-a", "a-", "a--b", "colima", "colima-x", "default", String(repeating: "a", count: 31),
        ]
        let good = ["work", "k8s-dev", String(repeating: "a", count: 30)]
        for name in bad {
            #expect(ProfileName.problem(newName: name, existing: []) != nil, "\(name)")
            let sb = try ScriptSandbox()
            let r = try run(sb, ["profile-create", "2", "2", "60"], profile: name)
            #expect(r.status == 1, "\(name)")
            #expect(r.out.contains("COLIMABAR_NOTIFY:Invalid profile name"), "\(name)")
            #expect(!sb.calls.contains { $0.hasPrefix("colima start") }, "\(name)")
        }
        for name in good {
            #expect(ProfileName.problem(newName: name, existing: []) == nil, "\(name)")
            let sb = try ScriptSandbox()
            #expect(try run(sb, ["profile-create", "2", "2", "60"], profile: name).status == 0, "\(name)")
        }
    }

    @Test func createRefusesAnExistingProfileAndBadValues() throws {
        let sb = try ScriptSandbox()
        try sb.write(".config/colima/work/colima.yaml", config)
        #expect(try run(sb, ["profile-create", "2", "2", "60"]).status == 1)
        #expect(try run(sb, ["profile-create", "2", "2", "5"], profile: "new").status == 1)
        #expect(try run(sb, ["profile-create", "x", "2", "60"], profile: "new").status == 1)
        #expect(try run(sb, ["profile-create", "2", "2", "60", "incus"], profile: "new").status == 1)
        #expect(!sb.calls.contains { $0.hasPrefix("colima start") })
    }

    @Test func deleteAsksWithTheProfileNameThenDeletes() throws {
        let sb = try ScriptSandbox()
        let r = try run(sb, ["profile-delete"])
        #expect(r.status == 0)
        #expect(dialogs(sb).contains("Delete profile 'work'? Colima deletes its VM and disk."))
        #expect(!dialogs(sb).contains("main Colima profile"))
        #expect(sb.calls.contains("colima delete --data --force --profile work"))
    }

    @Test func aCancelledDeleteDeletesNothing() throws {
        let sb = try ScriptSandbox()
        let r = try run(sb, ["profile-delete"], env: ["STUB_OSASCRIPT_EXIT": "1"])
        #expect(r.status == 2)
        #expect(dialogs(sb).contains("Delete profile 'work'?"))  // the stub got the dialog
        #expect(!sb.calls.contains { $0.hasPrefix("colima delete") })
    }

    @Test func deletingDefaultWarnsMore() throws {
        let sb = try ScriptSandbox()
        #expect(try run(sb, ["profile-delete"], profile: "default").status == 0)
        #expect(dialogs(sb).contains("'default' is the main Colima profile."))
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
    func vmDialogsNameTheProfile(args: [String], text: String) throws {
        let sb = try ScriptSandbox()
        try sb.write(".config/colima/work/colima.yaml", config)
        let r = try run(sb, args)
        #expect(r.status == 0, "\(r.out)")
        #expect(dialogs(sb).contains(text))
    }

    @Test func restartStopsAndStartsARunningVM() throws {
        // bash 3.2 must not end the action after `colima status` (see with_busy).
        let sb = try ScriptSandbox()
        #expect(try run(sb, ["restart"], env: ["STUB_COLIMA_STATUS": "0"]).status == 0)
        #expect(
            sb.calls == ["colima status --profile work", "colima stop --profile work", "colima start --profile work"])
    }

    @Test func failuresNameTheProfile() throws {
        let sb = try ScriptSandbox()
        try sb.stub("colima", "exit 1")
        let r = try run(sb, ["start"])
        #expect(r.status == 1)
        #expect(r.out.contains("COLIMABAR_NOTIFY:Start of profile 'work' failed"))
    }
}
