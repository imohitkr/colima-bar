import Foundation
import Testing

@testable import ColimaBar

/// The cleanup actions of `colima-ctl.sh`: `log-truncate`, `disk-trim`,
/// `auto-prune` and `prune cache` (see ScriptSandbox for the stub tools).
@Suite struct ColimaCtlCleanupTests {
    private let config = "cpu: 2\ndisk: 100\nmemory: 2\nrosetta: false\nkubernetes:\n  enabled: false\n"
    private let running = ["STUB_COLIMA_STATUS": "0"]
    private let id = String(repeating: "ab12", count: 16)
    private let fstrim = "/: 1.2 GiB (1288490188 bytes) trimmed on /dev/vda1"

    private func sandbox() throws -> ScriptSandbox {
        let sb = try ScriptSandbox()
        try sb.write(".config/colima/work/colima.yaml", config)
        return sb
    }

    private func dialogs(_ sb: ScriptSandbox) -> [String] { sb.calls.filter { $0.hasPrefix("osascript") } }
    private func notices(_ out: String) -> [String] {
        out.split(separator: "\n").filter { $0.hasPrefix("COLIMABAR_NOTIFY:") }.map(String.init)
    }

    // MARK: - Return Free Space

    @Test func trimRunsFstrimInTheVMOfTheProfile() async throws {
        let sb = try sandbox()
        let r = try await sb.ctl(["disk-trim"], env: running.merging(["STUB_COLIMA_SSH_OUT": fstrim]) { $1 })
        #expect(r.status == 0)
        #expect(sb.calls.contains("colima ssh --profile work -- sudo -n fstrim -av"))
        #expect(r.out.contains(fstrim))
        #expect(sb.leavesNoLockOrBusyMarker)
    }

    @Test func trimOfAStoppedVMNotifiesAndRunsNothing() async throws {
        let sb = try sandbox()
        let r = try await sb.ctl(["disk-trim"])
        #expect(r.status == 1)
        #expect(
            notices(r.out) == ["COLIMABAR_NOTIFY:The VM of profile 'work' is not running. Start it, then try again."])
        #expect(!sb.calls.contains { $0.hasPrefix("colima ssh") || $0.hasPrefix("colima start") })
    }

    @Test func trimWithAHeldLockExitsWith2() async throws {
        let sb = try sandbox()
        let dir = sb.home + "/.cache/colima-bar/lock.work"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try "300".write(toFile: dir + "/pid", atomically: true, encoding: .utf8)
        try sb.setAge(dir + "/pid", seconds: 120)
        try sb.setAge(dir, seconds: 120)
        try sb.stubProcesses([.init(pid: 300, age: 4 * 3600, command: "bash /x/colima-ctl.sh restart")])
        let r = try await sb.ctl(["disk-trim"], env: running)
        #expect(r.status == 2)
        #expect(notices(r.out) == ["COLIMABAR_NOTIFY:Another Colima action is still running for profile 'work'."])
        #expect(!sb.calls.contains { $0.hasPrefix("colima ssh") })
    }

    @Test func aFailedTrimNotifies() async throws {
        let sb = try sandbox()
        let r = try await sb.ctl(["disk-trim"], env: running.merging(["STUB_COLIMA_SSH_EXIT": "1"]) { $1 })
        #expect(r.status == 1)
        #expect(
            notices(r.out) == [
                "COLIMABAR_NOTIFY:Couldn't return the free space of profile 'work' to the Mac - see ~/.cache/colima-bar/ctl.log"
            ])
        #expect(sb.leavesNoLockOrBusyMarker)
    }

    /// fstrim exits with 64 when some file systems fail and others work.
    @Test func aPartialTrimIsASuccessThatKeepsTheOutput() async throws {
        let sb = try sandbox()
        let r = try await sb.ctl(
            ["disk-trim"], env: running.merging(["STUB_COLIMA_SSH_OUT": fstrim, "STUB_COLIMA_SSH_EXIT": "64"]) { $1 })
        #expect(r.status == 0)
        #expect(DiskTrim.trimmedBytes(in: r.out) == 1_288_490_188)
        #expect(notices(r.out).isEmpty)
    }

    /// `colima ssh` may report every remote failure as exit 1.
    @Test func anyExitWithATrimmedLineIsASuccess() async throws {
        let sb = try sandbox()
        let r = try await sb.ctl(
            ["disk-trim"], env: running.merging(["STUB_COLIMA_SSH_OUT": fstrim, "STUB_COLIMA_SSH_EXIT": "1"]) { $1 })
        #expect(r.status == 0)
        #expect(DiskTrim.trimmedBytes(in: r.out) == 1_288_490_188)
        #expect(notices(r.out).isEmpty)
    }

    @Test func exit64WithNothingTrimmedFails() async throws {
        let sb = try sandbox()
        let r = try await sb.ctl(
            ["disk-trim"],
            env: running.merging(["STUB_COLIMA_SSH_OUT": "fstrim: /boot/efi: failed", "STUB_COLIMA_SSH_EXIT": "64"]) {
                $1
            })
        #expect(r.status == 1)
    }

    @Test func trimAsksNothing() async throws {
        let sb = try sandbox()
        _ = try await sb.ctl(["disk-trim"], env: running)
        #expect(dialogs(sb).isEmpty)
    }

    // MARK: - Empty a log

    @Test func emptyingALogAsksWithTheNameThenTruncatesThePath() async throws {
        let sb = try sandbox()
        let r = try await sb.ctl(["log-truncate", id, "api"], env: running)
        #expect(r.status == 0)
        #expect(
            dialogs(sb).contains {
                $0.contains("Empty the log of container api in profile 'work'? docker logs then shows only new lines.")
            })
        #expect(
            sb.calls.contains(
                "colima ssh --profile work -- sudo -n truncate -c -s 0 -- /var/lib/docker/containers/\(id)/\(id)-json.log"
            ))
    }

    @Test(arguments: [
        "", String(repeating: "a", count: 63), String(repeating: "a", count: 65), String(repeating: "A", count: 64),
        "../../etc/passwd", String(repeating: "a", count: 63) + " ", String(repeating: "a", count: 63) + ";",
    ])
    func emptyingALogRefusesABadID(bad: String) async throws {
        let sb = try sandbox()
        let r = try await sb.ctl(["log-truncate", bad, "api"], env: running)
        #expect(r.status == 1)
        #expect(notices(r.out) == ["COLIMABAR_NOTIFY:Couldn't empty the log: the container ID is not valid."])
        #expect(dialogs(sb).isEmpty)
        #expect(!sb.calls.contains { $0.hasPrefix("colima ssh") })
    }

    @Test(arguments: ["a b", "$(x)", "", "a;b"])
    func aBadNameShowsTheShortID(name: String) async throws {
        let sb = try sandbox()
        let r = try await sb.ctl(["log-truncate", id, name], env: running)
        #expect(r.status == 0)
        #expect(dialogs(sb).contains { $0.contains("Empty the log of container \(id.prefix(12)) in profile 'work'?") })
    }

    @Test func aCancelledEmptyChangesNothing() async throws {
        let sb = try sandbox()
        let r = try await sb.ctl(
            ["log-truncate", id, "api"], env: running.merging(["STUB_OSASCRIPT_EXIT": "1"]) { $1 })
        #expect(r.status == 2)
        #expect(!sb.calls.contains { $0.hasPrefix("colima ssh") })
    }

    @Test func aVMThatStopsDuringTheDialogIsNotTruncated() async throws {
        let sb = try sandbox()
        let r = try await sb.ctl(
            ["log-truncate", id, "api"], env: running.merging(["STUB_OSASCRIPT_STOPS_VM": "1"]) { $1 })
        #expect(r.status == 1)
        #expect(
            notices(r.out) == ["COLIMABAR_NOTIFY:The VM of profile 'work' stopped. Start it, then try again."])
        #expect(!sb.calls.contains { $0.hasPrefix("colima ssh") })
    }

    @Test func emptyingALogOfAStoppedVMAsksNothing() async throws {
        let sb = try sandbox()
        let r = try await sb.ctl(["log-truncate", id, "api"])
        #expect(r.status == 1)
        #expect(
            notices(r.out) == ["COLIMABAR_NOTIFY:The VM of profile 'work' is not running. Start it, then try again."])
        #expect(dialogs(sb).isEmpty)
    }

    // MARK: - Prune

    @Test func pruneCacheAsksThenPrunesTheBuilderCache() async throws {
        let sb = try sandbox()
        let r = try await sb.ctl(["prune", "cache"], env: running)
        #expect(r.status == 0)
        #expect(
            dialogs(sb).contains {
                $0.contains("Remove the unused build cache of profile 'work'? The next builds take longer.")
            })
        #expect(sb.calls.contains("docker builder prune -f"))
        #expect(!sb.calls.contains { $0.hasPrefix("docker image prune") })
    }

    @Test func pruneDanglingStillRemovesImagesAndCache() async throws {
        let sb = try sandbox()
        let r = try await sb.ctl(["prune", "dangling"], env: running)
        #expect(r.status == 0)
        let docker = sb.calls.filter { $0.hasPrefix("docker ") }
        #expect(docker == ["docker image prune -f", "docker builder prune -f"])
    }

    // MARK: - Weekly cleanup

    @Test func weeklyCleanupPrunesWithoutADialog() async throws {
        let sb = try sandbox()
        let r = try await sb.ctl(["auto-prune"], env: running)
        #expect(r.status == 0)
        #expect(sb.calls.filter { $0.hasPrefix("docker ") } == ["docker image prune -f", "docker builder prune -f"])
        #expect(dialogs(sb).isEmpty)
        #expect(r.out.isEmpty)
        #expect(sb.leavesNoLockOrBusyMarker)
    }

    @Test func weeklyCleanupWritesTheBusyMarkerWhileItRuns() async throws {
        let sb = try sandbox()
        let marker = sb.home + "/.cache/colima-bar/busy.work"
        let r = try await sb.ctl(
            ["auto-prune"], env: running.merging(["STUB_DOCKER_PROBE": marker]) { $1 })
        #expect(r.status == 0)
        #expect(sb.calls.filter { $0 == "docker saw marker" }.count == 2)
        #expect(sb.leavesNoLockOrBusyMarker)
    }

    @Test func weeklyCleanupOfAStoppedVMExitsWith2Quietly() async throws {
        let sb = try sandbox()
        let r = try await sb.ctl(["auto-prune"])
        #expect(r.status == 2)
        #expect(r.out.isEmpty)
        #expect(!sb.calls.contains { $0.hasPrefix("docker ") || $0.hasPrefix("colima start") })
    }

    @Test func weeklyCleanupWithAHeldLockExitsWith2Quietly() async throws {
        let sb = try sandbox()
        let dir = sb.home + "/.cache/colima-bar/lock.work"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try "300".write(toFile: dir + "/pid", atomically: true, encoding: .utf8)
        try sb.setAge(dir + "/pid", seconds: 120)
        try sb.setAge(dir, seconds: 120)
        try sb.stubProcesses([.init(pid: 300, age: 4 * 3600, command: "bash /x/colima-ctl.sh restart")])
        let r = try await sb.ctl(["auto-prune"], env: running)
        #expect(r.status == 2)
        #expect(r.out.isEmpty)
        #expect(!sb.calls.contains { $0.hasPrefix("docker ") })
    }

    @Test func aFailedWeeklyCleanupNotifies() async throws {
        let sb = try sandbox()
        let r = try await sb.ctl(["auto-prune"], env: running.merging(["STUB_DOCKER_EXIT": "1"]) { $1 })
        #expect(r.status == 1)
        #expect(
            notices(r.out) == [
                "COLIMABAR_NOTIFY:The weekly cleanup of profile 'work' failed - see ~/.cache/colima-bar/ctl.log"
            ])
    }
}
