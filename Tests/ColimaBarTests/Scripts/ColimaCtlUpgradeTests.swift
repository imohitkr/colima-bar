import Foundation
import Testing

@testable import ColimaBar

/// The upgrade dialog of `colima-ctl.sh`, with stub `osascript`, `open` and
/// `colima` (see ScriptSandbox). No dialog opens and no page opens.
@Suite struct ColimaCtlUpgradeTests {
    private let colimaPage = "https://github.com/abiosoft/colima/releases/tag/v0.11.0"
    private let limaPage = "https://github.com/lima-vm/lima/releases/tag/v2.3.0"
    private let config = "cpu: 2\ndisk: 100\nmemory: 2\nrosetta: false\nkubernetes:\n  enabled: false\n"

    private func note(button: String, pages: String? = nil, running: Bool = false) -> [String: String] {
        var env = [
            "COLIMABAR_UPGRADE_NOTE": "Colima 0.10.3 → 0.11.0 since the last good start of profile 'work'.",
            "COLIMABAR_RELEASE_NOTES": pages ?? "\(colimaPage) \(limaPage)",
            "STUB_OSASCRIPT_OUT": button,
        ]
        if running { env.merge(["STUB_COLIMA_STATUS": "0", "COLIMABAR_EXPECT_RUNNING": "1"]) { $1 } }
        return env
    }

    /// The answer of osascript when the user clicks Cancel or the dialog gives up.
    private func cancelled(running: Bool) -> [String: String] {
        note(button: "", running: running).merging([
            "STUB_OSASCRIPT_EXIT": "1", "STUB_OSASCRIPT_ERR": "execution error: User canceled. (-128)",
        ]) { $1 }
    }

    private func osascriptCalls(_ sb: ScriptSandbox) -> [String] { sb.calls.filter { $0.hasPrefix("osascript") } }

    @Test func noNoteMeansNoUpgradeDialog() async throws {
        let sb = try ScriptSandbox()
        let r = try await sb.ctl(["start"])
        #expect(r.status == 0)
        #expect(osascriptCalls(sb).isEmpty)
        #expect(sb.calls.contains("colima start --profile work"))
    }

    @Test func continueStartsTheVM() async throws {
        let sb = try ScriptSandbox()
        let r = try await sb.ctl(["start"], env: note(button: "Continue"))
        #expect(r.status == 0)
        #expect(osascriptCalls(sb).count == 1)
        #expect(osascriptCalls(sb)[0].contains("Colima 0.10.3 → 0.11.0"))
        #expect(sb.calls.contains("colima start --profile work"))
        #expect(!sb.calls.contains { $0.hasPrefix("open ") })
    }

    @Test func cancelExitsWith2AndStartsNothing() async throws {
        let sb = try ScriptSandbox()
        let r = try await sb.ctl(["start"], env: cancelled(running: false))
        #expect(r.status == 2)
        #expect(!sb.calls.contains { $0.hasPrefix("colima start") })
        #expect(sb.leavesNoLockOrBusyMarker)
    }

    @Test func releaseNotesOpensTheTrustedPagesThenExitsWith2() async throws {
        let sb = try ScriptSandbox()
        let r = try await sb.ctl(["restart"], env: note(button: "Release Notes"))
        #expect(r.status == 2)
        #expect(sb.calls.filter { $0.hasPrefix("open ") } == ["open \(colimaPage)", "open \(limaPage)"])
        #expect(!sb.calls.contains { $0.hasPrefix("colima stop") || $0.hasPrefix("colima start") })
        #expect(sb.leavesNoLockOrBusyMarker)
    }

    @Test func releaseNotesOpensNoUntrustedPage() async throws {
        let bad = [
            "https://evil.example/abiosoft/colima/releases/tag/v1.0.0",
            "http://github.com/abiosoft/colima/releases/tag/v1.0.0",
            "https://github.com/other/repo/releases/tag/v1.0.0",
            "https://github.com/abiosoft/colima/releases/tag/v1.0.0;x",
            "file:///etc/passwd",
            "https://github.com/abiosoft/colima/releases/tag/v1/../../../../x/y/v1",
            "https://github.com/abiosoft/colima/releases/tag/v1.0.0/extra",
            "https://github.com/abiosoft/colima/releases/tag/v",
        ].joined(separator: " ")
        let sb = try ScriptSandbox()
        let r = try await sb.ctl(["start"], env: note(button: "Release Notes", pages: bad))
        #expect(r.status == 2)
        #expect(!sb.calls.contains { $0.hasPrefix("open ") })
    }

    @Test func resourcesWhileRunningAsksTheUpgradeDialogThenTheOwn() async throws {
        let sb = try ScriptSandbox()
        try sb.write(".config/colima/work/colima.yaml", config)
        let r = try await sb.ctl(["resources", "4", "8"], env: note(button: "Continue", running: true))
        #expect(r.status == 0)
        let dialogs = osascriptCalls(sb)
        #expect(dialogs.count == 2)
        #expect(dialogs[0].contains("Colima 0.10.3 → 0.11.0"))
        #expect(dialogs[1].contains("Restart the Colima VM of profile 'work' with 4 CPU / 8 GB RAM?"))
    }

    @Test func aCancelledUpgradeDialogChangesNoConfig() async throws {
        let sb = try ScriptSandbox()
        try sb.write(".config/colima/work/colima.yaml", config)
        let r = try await sb.ctl(["resources", "4", "8"], env: cancelled(running: true))
        #expect(r.status == 2)
        let yaml = try String(contentsOfFile: "\(sb.home)/.config/colima/work/colima.yaml", encoding: .utf8)
        #expect(yaml == config)
        #expect(osascriptCalls(sb).count == 1)
    }

    @Test func aDialogThatCannotShowStopsWithAnAlertAndExit1() async throws {
        let sb = try ScriptSandbox()
        let env = note(button: "").merging([
            "STUB_OSASCRIPT_EXIT": "1",
            "STUB_OSASCRIPT_ERR": "execution error: Not authorized to send Apple events. (-1743)",
        ]) { $1 }
        let r = try await sb.ctl(["start"], env: env)
        #expect(r.status == 1)
        #expect(r.out.contains("COLIMABAR_NOTIFY:Couldn't show the upgrade dialog for profile 'work'"))
        #expect(!sb.calls.contains { $0.hasPrefix("colima start") })
        #expect(sb.leavesNoLockOrBusyMarker)
    }

    @Test func aFailedOpenOfTheReleaseNotesStillExitsWith2() async throws {
        let sb = try ScriptSandbox()
        try sb.stub("open", "printf 'open %s\\n' \"$*\" >> \"\(sb.log)\"\nexit 1")
        let r = try await sb.ctl(["start"], env: note(button: "Release Notes", pages: colimaPage))
        #expect(r.status == 2)
        #expect(sb.calls.filter { $0.hasPrefix("open ") } == ["open \(colimaPage)"])
    }

    @Test(arguments: [
        (["rosetta", "on"], "Turn Rosetta"),
        (["k8s", "on"], "Kubernetes"),
        (["disk", "120"], "Grow the Colima disk"),
    ])
    func aConfigChangeWhileRunningAsksTheUpgradeDialogFirst(args: [String], own: String) async throws {
        let sb = try ScriptSandbox()
        try sb.write(".config/colima/work/colima.yaml", config)
        let r = try await sb.ctl(args, env: note(button: "Continue", running: true))
        #expect(r.status == 0)
        let dialogs = osascriptCalls(sb)
        #expect(dialogs.count == 2)
        #expect(dialogs[0].contains("Colima 0.10.3 → 0.11.0"))
        #expect(dialogs[1].contains(own))
        #expect(sb.calls.contains("colima start --profile work"))
    }

    @Test func aDiskChangeOfAStoppedVMAsksNoUpgradeDialogAndPrintsNoStartMarker() async throws {
        let sb = try ScriptSandbox()
        try sb.write(".config/colima/work/colima.yaml", config)
        let r = try await sb.ctl(["disk", "120"], env: note(button: "Continue"))
        #expect(r.status == 0)
        #expect(osascriptCalls(sb).count == 1)
        #expect(!UpgradeGuard.started(in: r.out))
        #expect(!sb.calls.contains { $0.hasPrefix("colima start") })
    }

    @Test func aGoodStartPrintsTheStartMarkerOnlyForColimaBar() async throws {
        let sb = try ScriptSandbox()
        let app = try await sb.ctl(["start"])
        #expect(app.status == 0 && UpgradeGuard.started(in: app.out))
        let byHand = try await sb.bash([sb.copy("colima-ctl.sh"), "start"], env: ["COLIMABAR_PROFILE": "work"])
        #expect(byHand.status == 0 && !UpgradeGuard.started(in: byHand.out))
    }

    @Test func aFailedStartPrintsNoStartMarker() async throws {
        let sb = try ScriptSandbox()
        try sb.stub("colima", "printf 'colima %s\\n' \"$*\" >> \"\(sb.log)\"\nexit 1")
        let r = try await sb.ctl(["start"])
        #expect(r.status == 1)
        #expect(!UpgradeGuard.started(in: r.out))
    }

    @Test func aCancelledStartPrintsNoStartMarker() async throws {
        let sb = try ScriptSandbox()
        let r = try await sb.ctl(["start"], env: cancelled(running: false))
        #expect(r.status == 2)
        #expect(!UpgradeGuard.started(in: r.out))
    }

    @Test func aRestartWhileRunningPrintsTheStartMarkerAfterTheStart() async throws {
        let sb = try ScriptSandbox()
        try sb.write(".config/colima/work/colima.yaml", config)
        let r = try await sb.ctl(["resources", "4", "8"], env: note(button: "Continue", running: true))
        #expect(r.status == 0 && UpgradeGuard.started(in: r.out))
    }

    @Test(arguments: [
        ["restart"], ["repair"], ["profile-create", "2", "4", "60", "docker"],
    ])
    func everyStartPathPrintsTheStartMarker(args: [String]) async throws {
        let sb = try ScriptSandbox()
        if args[0] != "profile-create" { try sb.write(".config/colima/work/colima.yaml", config) }
        let r = try await sb.ctl(args)
        #expect(r.status == 0)
        #expect(UpgradeGuard.started(in: r.out))
        #expect(!r.out.contains("COLIMABAR_NOTIFY"))
    }
}
