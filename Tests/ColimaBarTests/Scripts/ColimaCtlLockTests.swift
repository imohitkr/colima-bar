import Foundation
import Testing

@testable import ColimaBar

/// The lock and the busy marker of `colima-ctl.sh`: both hold the PID of the
/// script, and the script judges a leftover by that owner (see ScriptSandbox
/// for the stub `ps`).
@Suite struct ColimaCtlLockTests {
    private let minute: TimeInterval = 60
    private func state(_ sb: ScriptSandbox) -> String { sb.home + "/.cache/colima-bar" }

    /// A leftover lock of a profile `work`, with an owner PID and an age.
    private func lock(_ sb: ScriptSandbox, pid: String?, age: TimeInterval) throws {
        let dir = state(sb) + "/lock.work"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        if let pid {
            try pid.write(toFile: dir + "/pid", atomically: true, encoding: .utf8)
            try sb.setAge(dir + "/pid", seconds: age)
        }
        try sb.setAge(dir, seconds: age)
    }

    private let script = ScriptSandbox.FakeProcess(pid: 300, age: 4 * 3600, command: "bash /x/colima-ctl.sh restart")

    @Test func aLockWhoseOwnerIsGoneIsTakenOver() async throws {
        let sb = try ScriptSandbox()
        try lock(sb, pid: "999", age: 2 * minute)
        let r = try await sb.ctl(["start"])
        #expect(r.status == 0)
        #expect(sb.calls.contains("colima start --profile work"))
        #expect(!FileManager.default.fileExists(atPath: state(sb) + "/lock.work"))
    }

    @Test func aLockWithAnEmptyPIDFileKeepsItsLockUntilItIsOld() async throws {
        // The owner writes its PID now, or the read failed: that says nothing about the owner.
        let fresh = try ScriptSandbox()
        try lock(fresh, pid: "", age: 2 * minute)
        #expect(try await fresh.ctl(["start"]).status == 2)
        #expect(FileManager.default.fileExists(atPath: state(fresh) + "/lock.work"))
        let old = try ScriptSandbox()
        try lock(old, pid: "", age: 31 * minute)
        #expect(try await old.ctl(["start"]).status == 0)
    }

    @Test func aLockWithAnUnreadablePIDFileIsNotTakenOver() async throws {
        let sb = try ScriptSandbox()
        try lock(sb, pid: "300", age: 2 * minute)
        let file = state(sb) + "/lock.work/pid"
        chmod(file, 0)
        defer { chmod(file, 0o644) }
        #expect(try await sb.ctl(["start"]).status == 2)
        #expect(sb.calls.isEmpty)
    }

    @Test func theLockPIDIsWrittenThroughATemporaryFile() async throws {
        let sb = try ScriptSandbox()
        try sb.stub(
            "colima",
            """
            [ "$1" = start ] || exit 0
            ls "$HOME/.cache/colima-bar/lock.work" > "$HOME/lock.listing"
            exit 0
            """)
        #expect(try await sb.ctl(["start"]).status == 0)
        let listing = try String(contentsOfFile: sb.home + "/lock.listing", encoding: .utf8)
        #expect(listing.split(separator: "\n").map(String.init) == ["pid"])
    }

    @Test func aLockWhoseOwnerRunsIsRefusedAfterALongSleep() async throws {
        // The action runs for hours of Mac sleep: age alone must not free the lock.
        let sb = try ScriptSandbox()
        try sb.stubProcesses([script])
        try lock(sb, pid: "300", age: 31 * minute)
        let r = try await sb.ctl(["start"])
        #expect(r.status == 2)
        #expect(r.out.contains("Another Colima action is still running"))
        #expect(sb.calls.isEmpty)
        #expect(FileManager.default.fileExists(atPath: state(sb) + "/lock.work/pid"))
    }

    @Test func aLockWhoseOwnerPIDWasReusedIsTakenOver() async throws {
        // The process with the PID started after the lock was made.
        let sb = try ScriptSandbox()
        try sb.stubProcesses([.init(pid: 300, age: 30, command: "bash /x/colima-ctl.sh start")])
        try lock(sb, pid: "300", age: 10 * minute)
        #expect(try await sb.ctl(["start"]).status == 0)
    }

    @Test func aLockWhoseOwnerIsAnotherProgramIsTakenOver() async throws {
        let sb = try ScriptSandbox()
        try sb.stubProcesses([.init(pid: 300, age: 3600, command: "/usr/bin/vim notes.txt")])
        try lock(sb, pid: "300", age: 10 * minute)
        #expect(try await sb.ctl(["start"]).status == 0)
    }

    @Test func aLockWithNoPIDFollowsTheOldAgeRule() async throws {
        let fresh = try ScriptSandbox()
        try lock(fresh, pid: nil, age: 5 * minute)
        #expect(try await fresh.ctl(["start"]).status == 2)
        let old = try ScriptSandbox()
        try lock(old, pid: nil, age: 31 * minute)
        #expect(try await old.ctl(["start"]).status == 0)
    }

    @Test func theLockAndTheBusyMarkerHoldThePIDOfTheScript() async throws {
        let sb = try ScriptSandbox()
        // The VM action runs while the stub colima copies both files.
        try sb.stub(
            "colima",
            """
            printf 'colima %s\\n' "$*" >> "\(sb.log)"
            [ "$1" = start ] || exit 0
            cp "$HOME/.cache/colima-bar/busy.work" "$HOME/busy.copy"
            cp "$HOME/.cache/colima-bar/lock.work/pid" "$HOME/lock.copy"
            exit 0
            """)
        #expect(try await sb.ctl(["start"]).status == 0)
        let busy = try String(contentsOfFile: sb.home + "/busy.copy", encoding: .utf8)
        let owner = try String(contentsOfFile: sb.home + "/lock.copy", encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let marker = BusyMarker.parse(busy)
        #expect(marker.label == "Starting work")
        #expect(marker.pid == Int(owner))
        #expect(marker.pid != nil)
        // Both files go away when the action ends.
        #expect(sb.leavesNoLockOrBusyMarker)
    }
}
