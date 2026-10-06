import Foundation
import Testing
@testable import ColimaBar

@Suite struct ContainerHealthTests {
    /// The parser that ran on every read before health became stored.
    private func oldHealth(_ status: String) -> String? {
        for h in ["unhealthy", "healthy", "health: starting"] where status.contains("(\(h))") { return h }
        return nil
    }

    private func ctr(_ status: String, state: String = "running") -> Container {
        Container(id: "x", name: "x", image: "i", state: state, status: status, ports: [], project: nil)
    }

    @Test func storedHealthMatchesTheOldParser() {
        for status in ["Up 2 hours (healthy)", "Up 1 minute (unhealthy)", "Up 5 seconds (health: starting)",
                       "Up 3 days", "Exited (1) 2 minutes ago", "Created", "", "Up 1 hour (Paused)",
                       "Up 4 minutes (healthy) (unhealthy)"] {
            #expect(ctr(status).health == oldHealth(status), "\(status)")
            #expect(Container.health(status: status) == oldHealth(status), "\(status)")
        }
    }

    @Test func eachStatusMapsToItsHealth() {
        #expect(ctr("Up 2 hours (healthy)").health == "healthy")
        #expect(ctr("Up 1 minute (unhealthy)").health == "unhealthy")
        #expect(ctr("Up 5 seconds (health: starting)").health == "health: starting")
        #expect(ctr("Up 3 days").health == nil)
    }

    @Test func derivedListsSplitAndCount() {
        let list = [ctr("Up 1 minute (unhealthy)"), ctr("Exited (0) 1 hour ago", state: "exited"),
                    ctr("Up 2 hours (healthy)", state: "paused"), ctr("Restarting", state: "restarting"),
                    ctr("Created", state: "created")]
        let d = ColimaModel.derivedLists(list)
        #expect(d.running == list.filter(\.isRunning))
        #expect(d.stopped == list.filter { !$0.isRunning })
        #expect(d.running.count == 3 && d.stopped.count == 2)
        #expect(d.unhealthy == 1)
        let empty = ColimaModel.derivedLists([])
        #expect(empty.running.isEmpty && empty.stopped.isEmpty && empty.unhealthy == 0)
    }
}

@Suite struct HeartbeatTimingTests {
    @Test func staleLimitIsLongerOnlyWhileStopped() {
        #expect(ColimaModel.staleAfter(state: .stopped) == 300)
        #expect(ColimaModel.staleAfter(state: .running) == 60)
        #expect(ColimaModel.staleAfter(state: .unknown) == 60)
        #expect(ColimaModel.staleAfter(state: .notInstalled) == 60)
    }

    @Test func tickSlowsOnlyWhenStoppedIdleAndClosed() {
        #expect(ColimaModel.tickInterval(state: .stopped, busy: false, dashboardOpen: false) == .seconds(5))
        #expect(ColimaModel.tickInterval(state: .stopped, busy: false, dashboardOpen: true) == .seconds(1))
        #expect(ColimaModel.tickInterval(state: .stopped, busy: true, dashboardOpen: false) == .seconds(1))
        #expect(ColimaModel.tickInterval(state: .running, busy: false, dashboardOpen: false) == .seconds(1))
        #expect(ColimaModel.tickInterval(state: .unknown, busy: false, dashboardOpen: false) == .seconds(1))
        #expect(ColimaModel.tickInterval(state: .notInstalled, busy: false, dashboardOpen: false) == .seconds(1))
    }
}

@Suite(.serialized) struct DirWatcherTests {
    private func tempRoot() throws -> String {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("colimabar-watch-\(UUID().uuidString)").path
        let fm = FileManager.default
        for d in ["default", "work", "_store", ".hidden", "_lima/colima", "_lima/colima-work", "_lima/_config"] {
            try fm.createDirectory(atPath: "\(root)/\(d)", withIntermediateDirectories: true)
        }
        fm.createFile(atPath: "\(root)/ssh_config", contents: Data())
        return root
    }

    @Test func watchesProfilesAndLimaInstancesOnly() throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        #expect(ColimaDirWatcher.watchPaths(root: root) == [
            root, "\(root)/default", "\(root)/work",
            "\(root)/_lima", "\(root)/_lima/colima", "\(root)/_lima/colima-work",
        ])
        #expect(ColimaDirWatcher.watchPaths(root: "\(root)/missing").isEmpty)
    }

    /// Waits up to `seconds` for `cond`, letting the main queue run.
    @MainActor private func wait(_ seconds: Double, _ cond: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if cond() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return cond()
    }

    @MainActor @Test func instanceChangesFireOnceAndNewDirsAreWatched() async throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        var fired = 0
        let w = ColimaDirWatcher(root: root, debounce: .milliseconds(100), minGap: .milliseconds(200)) { fired += 1 }
        #expect(w.watched.contains("\(root)/_lima/colima"))

        // Lima creates ha.pid and ha.sock together: one callback for the burst.
        let fm = FileManager.default
        fm.createFile(atPath: "\(root)/_lima/colima/ha.pid", contents: Data("1".utf8))
        fm.createFile(atPath: "\(root)/_lima/colima/ha.sock", contents: Data())
        #expect(await wait(3) { fired >= 1 })
        try? await Task.sleep(for: .milliseconds(300))
        #expect(fired == 1)

        // A new profile appears: its directories get watched too.
        try fm.createDirectory(atPath: "\(root)/_lima/colima-new", withIntermediateDirectories: true)
        #expect(await wait(3) { fired >= 2 })
        #expect(w.watched.contains("\(root)/_lima/colima-new"))

        // The profile goes away: its watch is dropped.
        try fm.removeItem(atPath: "\(root)/_lima/colima-new")
        #expect(await wait(3) { fired >= 3 && !w.watched.contains("\(root)/_lima/colima-new") })
    }

    @MainActor @Test func steadyChangesAreDelayedNotDropped() async throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        var fires: [ContinuousClock.Instant] = []
        let w = ColimaDirWatcher(root: root, debounce: .milliseconds(50), minGap: .milliseconds(400)) {
            fires.append(.now)
        }
        // A change every 50 ms for 1 s: callbacks keep coming, spaced by minGap.
        let fm = FileManager.default
        for i in 0..<20 {
            fm.createFile(atPath: "\(root)/default/f\(i)", contents: Data())
            try? await Task.sleep(for: .milliseconds(50))
        }
        #expect(await wait(3) { fires.count >= 3 })
        for (a, b) in zip(fires, fires.dropFirst()) { #expect(b - a >= .milliseconds(350)) }
        withExtendedLifetime(w) {}
    }
}
