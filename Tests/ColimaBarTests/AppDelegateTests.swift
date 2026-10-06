import Foundation
import Testing

@testable import ColimaBar

@Suite struct DashboardWindowCountTests {
    @Test func windowCountsOnlyWhileOnScreen() {
        #expect(AppDelegate.windowCounts(visible: true, miniaturized: false, debug: false))
        #expect(!AppDelegate.windowCounts(visible: false, miniaturized: false, debug: false))  // behind others, locked
        #expect(!AppDelegate.windowCounts(visible: true, miniaturized: true, debug: false))
        #expect(!AppDelegate.windowCounts(visible: false, miniaturized: true, debug: false))
    }

    @Test func snapshotWindowOffScreenStillCounts() {
        #expect(AppDelegate.windowCounts(visible: false, miniaturized: false, debug: true))
        #expect(!AppDelegate.windowCounts(visible: false, miniaturized: true, debug: true))
    }
}
