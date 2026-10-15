import Foundation
import Testing

@testable import ColimaBar

/// `colima-ctl.sh stale-files` and `repair`, with stub tools and a stub `ps`
/// (see ScriptSandbox). Nothing here touches the real Colima or Lima folders.
@Suite struct ColimaCtlStaleFilesTests {
    private let config = "cpu: 2\ndisk: 100\nmemory: 2\n"
    /// A Lima process that started long before the pid files below.
    private let lima = ScriptSandbox.FakeProcess(
        pid: 100, age: 3600, command: "limactl hostagent --pidfile x colima-work")
    /// An unrelated process that started after the pid files: it reused a PID.
    private let other = ScriptSandbox.FakeProcess(pid: 200, age: 30, command: "/usr/bin/python3 job.py")

    private func lima(_ sb: ScriptSandbox, _ relative: String) -> String { "\(sb.home)/.colima/_lima/\(relative)" }

    /// Writes a pid file below Lima's folder that is 10 minutes old.
    @discardableResult
    private func pidFile(_ sb: ScriptSandbox, _ relative: String, _ text: String) throws -> String {
        try sb.write(".colima/_lima/\(relative)", text)
        let path = lima(sb, relative)
        try sb.setAge(path, seconds: 600)
        return path
    }

    /// Writes the pid file of the Colima daemon of the profile `work`, 10 minutes old.
    @discardableResult
    private func daemonPid(_ sb: ScriptSandbox, _ text: String, profile: String = "work") throws -> String {
        try sb.write(".colima/\(profile)/daemon/daemon.pid", text)
        let path = "\(sb.home)/.colima/\(profile)/daemon/daemon.pid"
        try sb.setAge(path, seconds: 600)
        return path
    }

    private func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: path) }

    private func setUp(_ sb: ScriptSandbox) throws {
        try sb.write(".colima/work/colima.yaml", config)
        try sb.stubProcesses([lima, other])
    }

    private func lines(_ out: String) -> [[String]] {
        out.split(separator: "\n").map { $0.split(separator: "\t", omittingEmptySubsequences: false).map(String.init) }
    }

    // MARK: stale-files

    @Test func staleFilesListsGoneReusedAndInvalidFiles() async throws {
        let sb = try ScriptSandbox()
        try setUp(sb)
        let ha = try pidFile(sb, "colima-work/ha.pid", "200\n")
        let vz = try pidFile(sb, "colima-work/vz.pid", "300\n")
        let qemu = try pidFile(sb, "colima-work/qemu.pid", "not-a-pid\n")
        let r = try await sb.ctl(["stale-files"])
        #expect(r.status == 0)
        #expect(
            Set(lines(r.out).map { $0.joined(separator: "|") }) == [
                "reused|\(ha)|200", "gone|\(vz)|300", "invalid|\(qemu)|not-a-pid",
            ])
    }

    @Test func staleFilesSkipsALiveOwnerLinksAndFilesOfOtherNames() async throws {
        let sb = try ScriptSandbox()
        try setUp(sb)
        try pidFile(sb, "colima-work/ha.pid", "100\n")
        try pidFile(sb, "colima-work/real.pid", "300\n")
        try sb.write(".colima/_lima/colima-work/diffdisk", "300")
        try sb.write(".colima/_lima/colima-work/cidata.iso", "300")
        try sb.write(".colima/_lima/colima-work/lima.yaml", "300")
        try FileManager.default.createSymbolicLink(
            atPath: lima(sb, "colima-work/vz.pid"), withDestinationPath: lima(sb, "colima-work/real.pid"))
        // The folder of another profile is not ours.
        try pidFile(sb, "colima-other/ha.pid", "300\n")
        let r = try await sb.ctl(["stale-files"])
        #expect(r.status == 0)
        #expect(r.out.isEmpty)
    }

    @Test func staleFilesCountsTheNetworkFileOnlyWhenNoHostAgentRuns() async throws {
        let sb = try ScriptSandbox()
        try setUp(sb)
        let net = try pidFile(sb, "_networks/user-v2/usernet_user-v2.pid", "300\n")
        let free = try await sb.ctl(["stale-files"])
        #expect(lines(free.out) == [["gone", net, "300"]])
        // A host agent of another instance runs: the network folder is in use.
        try pidFile(sb, "colima-other/ha.pid", "100\n")
        let busy = try await sb.ctl(["stale-files"])
        #expect(busy.out.isEmpty)
    }

    @Test func staleFilesChangesNothingAndTakesNoLock() async throws {
        let sb = try ScriptSandbox()
        try setUp(sb)
        let ha = try pidFile(sb, "colima-work/ha.pid", "200\n")
        let r = try await sb.ctl(["stale-files"])
        #expect(r.status == 0)
        #expect(exists(ha))
        #expect(sb.calls.isEmpty)  // no colima, docker or dialog call
        #expect(sb.leavesNoLockOrBusyMarker)
    }

    // MARK: repair

    @Test func repairRemovesAReusedFileBeforeTheForceStopThenStarts() async throws {
        let sb = try ScriptSandbox()
        try setUp(sb)
        let ha = try pidFile(sb, "colima-work/ha.pid", "200\n")
        let vz = try pidFile(sb, "colima-work/vz.pid", "300\n")
        let disk = lima(sb, "colima-work/diffdisk")
        try sb.write(".colima/_lima/colima-work/diffdisk", "data")
        try sb.write(".colima/_lima/colima-work/cidata.iso", "data")
        // The stub logs which files exist when Colima stops and starts.
        try sb.stub(
            "colima",
            """
            printf 'colima %s\\n' "$*" >> "\(sb.log)"
            if [ "$1" = stop ]; then
              printf 'at-stop ha=%s vz=%s\\n' "$([ -e "\(ha)" ] && echo yes || echo no)" "$([ -e "\(vz)" ] && echo yes || echo no)" >> "\(sb.log)"
            fi
            exit 0
            """)
        let r = try await sb.ctl(["repair"])
        #expect(r.status == 0)
        let calls = sb.calls.filter { $0.hasPrefix("colima ") || $0.hasPrefix("at-stop") }
        #expect(
            calls == [
                "colima stop --force --profile work", "at-stop ha=no vz=yes", "colima start --profile work",
            ])
        #expect(!exists(vz))  // the gone file goes after the stop
        #expect(exists(disk) && exists(lima(sb, "colima-work/cidata.iso")))
        #expect(dialogs(sb).contains("colima-work/ha.pid (reused)"))
        #expect(dialogs(sb).contains("colima-work/vz.pid (gone)"))
    }

    @Test func repairKeepsAnyFileWhenTheUserCancels() async throws {
        let sb = try ScriptSandbox()
        try setUp(sb)
        let ha = try pidFile(sb, "colima-work/ha.pid", "200\n")
        let r = try await sb.ctl(["repair"], env: ["STUB_OSASCRIPT_EXIT": "1"])
        #expect(r.status == 2)
        #expect(exists(ha))
        #expect(!sb.calls.contains { $0.hasPrefix("colima ") })
        #expect(sb.leavesNoLockOrBusyMarker)
    }

    @Test func repairExitsWith2WhileAnotherActionHoldsTheLock() async throws {
        let sb = try ScriptSandbox()
        try setUp(sb)
        let owner = ScriptSandbox.FakeProcess(pid: 300, age: 3600, command: "bash /x/colima-ctl.sh start")
        try sb.stubProcesses([lima, other, owner])
        try sb.write(".cache/colima-bar/lock.work/pid", "300\n")
        try sb.setAge(sb.home + "/.cache/colima-bar/lock.work/pid", seconds: 600)
        let ha = try pidFile(sb, "colima-work/ha.pid", "200\n")
        let r = try await sb.ctl(["repair"])
        #expect(r.status == 2)
        #expect(exists(ha))
        #expect(sb.calls.isEmpty)
    }

    @Test func repairNeedsAColimaYaml() async throws {
        let sb = try ScriptSandbox()
        try sb.stubProcesses([lima, other])
        let ha = try pidFile(sb, "colima-work/ha.pid", "200\n")
        let r = try await sb.ctl(["repair"])
        #expect(r.status == 1)
        #expect(r.out.contains("COLIMABAR_NOTIFY:Can't repair profile 'work'"))
        #expect(exists(ha))
        #expect(sb.calls.isEmpty)
    }

    @Test func repairRefusesWhileAStartRuns() async throws {
        let sb = try ScriptSandbox()
        try setUp(sb)
        let start = ScriptSandbox.FakeProcess(
            pid: 555, age: 20, command: "/opt/homebrew/bin/colima start --profile work")
        try sb.stubProcesses([lima, other, start])
        try sb.stub("pgrep", "echo 555")
        let ha = try pidFile(sb, "colima-work/ha.pid", "200\n")
        let r = try await sb.ctl(["repair"])
        #expect(r.status == 1)
        #expect(r.out.contains("If it hangs, stop it (Ctrl-C), then try again."))
        #expect(exists(ha))
        #expect(dialogs(sb).isEmpty)
    }

    @Test func repairStopsWhenALimaProcessStillRunsAfterTheForceStop() async throws {
        let sb = try ScriptSandbox()
        try setUp(sb)
        let ha = try pidFile(sb, "colima-work/ha.pid", "100\n")  // a live host agent
        let vz = try pidFile(sb, "colima-work/vz.pid", "300\n")  // gone
        let r = try await sb.ctl(["repair"])
        #expect(r.status == 1)
        #expect(r.out.contains("The VM of profile 'work' still runs"))
        #expect(sb.calls.contains("colima stop --force --profile work"))
        #expect(!sb.calls.contains { $0.hasPrefix("colima start") })
        #expect(exists(ha) && exists(vz))  // nothing more is removed
    }

    @Test func repairKeepsALinkNamedHaPid() async throws {
        let sb = try ScriptSandbox()
        try setUp(sb)
        let real = try pidFile(sb, "elsewhere.pid", "300\n")
        let ha = lima(sb, "colima-work/ha.pid")
        try FileManager.default.createDirectory(
            atPath: lima(sb, "colima-work"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: ha, withDestinationPath: real)
        let r = try await sb.ctl(["repair"])
        #expect(r.status == 0)
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: ha)) == real)
        #expect(exists(real))
    }

    @Test func repairStartsEvenWhenTheForceStopFails() async throws {
        let sb = try ScriptSandbox()
        try setUp(sb)
        try sb.stub(
            "colima",
            """
            printf 'colima %s\\n' "$*" >> "\(sb.log)"
            [ "$1" = stop ] && exit 1
            exit 0
            """)
        let r = try await sb.ctl(["repair"])
        #expect(r.status == 0)
        #expect(sb.calls.contains("colima start --profile work"))
    }

    // MARK: daemon pid file

    @Test func staleFilesListsADaemonPidFileWhoseOwnerIsGoneOrReused() async throws {
        let sb = try ScriptSandbox()
        try setUp(sb)
        let daemon = try daemonPid(sb, "300\n")
        let gone = try await sb.ctl(["stale-files"])
        #expect(lines(gone.out) == [["gone", daemon, "300"]])
        // A process that is not the daemon has the PID.
        try daemonPid(sb, "200\n")
        let reused = try await sb.ctl(["stale-files"])
        #expect(lines(reused.out) == [["reused", daemon, "200"]])
    }

    @Test func staleFilesKeepsADaemonPidFileWhoseOwnerIsTheColimaDaemon() async throws {
        let sb = try ScriptSandbox()
        try setUp(sb)
        let daemon = ScriptSandbox.FakeProcess(
            pid: 400, age: 3600, command: "/opt/homebrew/bin/colima daemon start work --vmnet")
        try sb.stubProcesses([lima, other, daemon])
        try daemonPid(sb, "400\n")
        #expect(try await sb.ctl(["stale-files"]).out.isEmpty)
    }

    @Test func staleFilesIgnoresADaemonPidFileThatIsALink() async throws {
        let sb = try ScriptSandbox()
        try setUp(sb)
        let real = try pidFile(sb, "elsewhere.pid", "200\n")
        try FileManager.default.createDirectory(
            atPath: sb.home + "/.colima/work/daemon", withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            atPath: sb.home + "/.colima/work/daemon/daemon.pid", withDestinationPath: real)
        #expect(try await sb.ctl(["stale-files"]).out.isEmpty)
    }

    @Test func repairRemovesAReusedDaemonPidFileBeforeTheForceStop() async throws {
        let sb = try ScriptSandbox()
        try setUp(sb)
        let daemon = try daemonPid(sb, "200\n")
        try sb.stub(
            "colima",
            """
            printf 'colima %s\\n' "$*" >> "\(sb.log)"
            if [ "$1" = stop ]; then
              printf 'at-stop daemon=%s\\n' "$([ -e "\(daemon)" ] && echo yes || echo no)" >> "\(sb.log)"
            fi
            exit 0
            """)
        let r = try await sb.ctl(["repair"])
        #expect(r.status == 0)
        let calls = sb.calls.filter { $0.hasPrefix("colima ") || $0.hasPrefix("at-stop") }
        #expect(calls == ["colima stop --force --profile work", "at-stop daemon=no", "colima start --profile work"])
        #expect(dialogs(sb).contains("work/daemon/daemon.pid (reused)"))
    }

    @Test func repairRemovesADaemonPidFileWhoseOwnerIsGoneAfterTheForceStop() async throws {
        let sb = try ScriptSandbox()
        try setUp(sb)
        let daemon = try daemonPid(sb, "300\n")
        try sb.stub(
            "colima",
            """
            printf 'colima %s\\n' "$*" >> "\(sb.log)"
            if [ "$1" = stop ]; then
              printf 'at-stop daemon=%s\\n' "$([ -e "\(daemon)" ] && echo yes || echo no)" >> "\(sb.log)"
            fi
            exit 0
            """)
        #expect(try await sb.ctl(["repair"]).status == 0)
        #expect(sb.calls.contains("at-stop daemon=yes"))
        #expect(!exists(daemon))
    }

    @Test func repairKeepsADaemonPidFileWhoseOwnerIsTheColimaDaemon() async throws {
        let sb = try ScriptSandbox()
        try setUp(sb)
        let daemon = ScriptSandbox.FakeProcess(
            pid: 400, age: 3600, command: "/opt/homebrew/bin/colima daemon start work")
        try sb.stubProcesses([lima, other, daemon])
        let live = try daemonPid(sb, "400\n")
        #expect(try await sb.ctl(["repair"]).status == 0)
        #expect(exists(live))
    }

    // MARK: undeletable file

    @Test func repairStopsNothingWhenAReusedFileCannotBeRemoved() async throws {
        let sb = try ScriptSandbox()
        try setUp(sb)
        let ha = try pidFile(sb, "colima-work/ha.pid", "200\n")
        let folder = lima(sb, "colima-work")
        // A read-only folder: rm cannot unlink the file.
        chmod(folder, 0o555)
        defer { chmod(folder, 0o755) }
        let r = try await sb.ctl(["repair"])
        #expect(r.status == 1)
        #expect(r.out.contains("Can't remove"))
        #expect(r.out.contains("Nothing was stopped."))
        #expect(!sb.calls.contains { $0.hasPrefix("colima ") })
        #expect(exists(ha))
        #expect(sb.leavesNoLockOrBusyMarker)
    }

    // MARK: default profile

    @Test func theDefaultProfileUsesTheColimaInstanceFolder() async throws {
        let sb = try ScriptSandbox()
        try sb.write(".colima/default/colima.yaml", config)
        try sb.stubProcesses([lima, other])
        let ha = try pidFile(sb, "colima/ha.pid", "200\n")
        let daemon = try daemonPid(sb, "300\n", profile: "default")
        // The folder of the profile "work" is not used.
        try pidFile(sb, "colima-work/ha.pid", "200\n")
        let listed = try await sb.ctl(["stale-files"], profile: "default")
        #expect(Set(lines(listed.out).map { $0.joined(separator: "|") }) == ["reused|\(ha)|200", "gone|\(daemon)|300"])
        let r = try await sb.ctl(["repair"], profile: "default")
        #expect(r.status == 0)
        #expect(sb.calls.contains("colima stop --force --profile default"))
        #expect(sb.calls.contains("colima start --profile default"))
        #expect(!exists(ha) && !exists(daemon))
        #expect(exists(lima(sb, "colima-work/ha.pid")))
    }

    /// The text of the dialogs that the stub osascript got.
    private func dialogs(_ sb: ScriptSandbox) -> String {
        sb.calls.filter { !$0.hasPrefix("colima ") && !$0.hasPrefix("docker ") }.joined(separator: "\n")
    }
}
