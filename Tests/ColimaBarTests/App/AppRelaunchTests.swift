import Foundation
import Testing

@testable import ColimaBar

@Suite struct AppRelaunchTests {
    @Test func readsVersionFromInfoPlistOnDisk() throws {
        let bundle = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppRelaunchTests-\(UUID().uuidString).app")
        defer { try? FileManager.default.removeItem(at: bundle) }
        let contents = bundle.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let write = { (version: String) in
            let data = try PropertyListSerialization.data(
                fromPropertyList: ["CFBundleShortVersionString": version], format: .xml, options: 0)
            try data.write(to: contents.appendingPathComponent("Info.plist"))
        }
        try write("1.0.0")
        #expect(AppDelegate.onDiskVersion(of: bundle) == "1.0.0")
        // A later read sees the replaced file, not a cached copy.
        try write("1.1.0")
        #expect(AppDelegate.onDiskVersion(of: bundle) == "1.1.0")
    }

    @Test func missingPlistGivesNil() {
        let bundle = URL(fileURLWithPath: "/nonexistent/ColimaBar.app")
        #expect(AppDelegate.onDiskVersion(of: bundle) == nil)
    }

    @Test func restartsOnlyWhenTheBundleOnDiskChanged() {
        #expect(AppDelegate.restart(running: "0.3.0", onDisk: "0.3.0", isAgent: true) == .none)
        #expect(AppDelegate.restart(running: "0.3.0", onDisk: nil, isAgent: false) == .none)
        #expect(AppDelegate.restart(running: "0.3.0", onDisk: "0.4.0", isAgent: true) == .agent)
        #expect(AppDelegate.restart(running: "0.3.0", onDisk: "0.4.0", isAgent: false) == .manual)
        #expect(AppDelegate.restart(running: "0.4.0", onDisk: "0.3.0", isAgent: false) == .manual)  // downgrade
    }

    @Test func newerInstalledCopyTakesOver() {
        #expect(AppDelegate.takesOver(mine: "0.4.0", other: "0.3.0", installed: true))
        #expect(!AppDelegate.takesOver(mine: "0.4.0", other: "0.3.0", installed: false))  // DMG, Downloads
        #expect(!AppDelegate.takesOver(mine: "0.3.0", other: "0.3.0", installed: true))  // same version: reopen
        #expect(!AppDelegate.takesOver(mine: "0.3.0", other: "0.4.0", installed: true))
        #expect(!AppDelegate.takesOver(mine: "0.4.0", other: nil, installed: true))
        #expect(!AppDelegate.takesOver(mine: "dev", other: "0.3.0", installed: true))
    }

    @Test func revealRequestCountsFor60Seconds() {
        let now = 1_000_000.0
        #expect(AppDelegate.revealRequestIsFresh(now - 5, now: now))
        #expect(!AppDelegate.revealRequestIsFresh(now - 60, now: now))
        #expect(!AppDelegate.revealRequestIsFresh(now - 3600, now: now))
        #expect(!AppDelegate.revealRequestIsFresh(now + 30, now: now))  // clock went back
        #expect(!AppDelegate.revealRequestIsFresh(nil, now: now))
    }
}
