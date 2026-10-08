import Foundation
import Testing

@testable import ColimaBar

@Suite(.serialized) struct ColimaDirWatcherTests {
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
        #expect(
            ColimaDirWatcher.watchPaths(root: root) == [
                root, "\(root)/default", "\(root)/work",
                "\(root)/_lima", "\(root)/_lima/colima", "\(root)/_lima/colima-work",
            ])
        #expect(ColimaDirWatcher.watchPaths(root: "\(root)/missing").isEmpty)
    }

    @Test func watchesASeparateLimaFolder() throws {
        // LIMA_HOME moves the Lima instances out of the Colima config folder.
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let lima = "\(root)/_lima"
        #expect(
            ColimaDirWatcher.watchPaths(root: "\(root)/default", lima: lima) == [
                "\(root)/default", lima, "\(lima)/colima", "\(lima)/colima-work",
            ])
        #expect(ColimaDirWatcher.watchPaths(root: "\(root)/missing", lima: lima).count == 3)
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
        #expect(await waitUntil { fired >= 1 })
        // No event shows that a second callback will not come, so give it
        // longer than the debounce to arrive.
        try? await Task.sleep(for: .milliseconds(300))
        #expect(fired == 1)

        // A new profile appears: its directories get watched too.
        try fm.createDirectory(atPath: "\(root)/_lima/colima-new", withIntermediateDirectories: true)
        #expect(await waitUntil { fired >= 2 })
        #expect(w.watched.contains("\(root)/_lima/colima-new"))

        // The profile goes away: its watch is dropped.
        try fm.removeItem(atPath: "\(root)/_lima/colima-new")
        #expect(await waitUntil { fired >= 3 && !w.watched.contains("\(root)/_lima/colima-new") })
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
        #expect(await waitUntil { fires.count >= 3 })
        for (a, b) in zip(fires, fires.dropFirst()) { #expect(b - a >= .milliseconds(350)) }
        withExtendedLifetime(w) {}
    }
}
