import Foundation
import Testing

@testable import ColimaBar

@Suite struct AppDelegateTests {
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

    @Test func theCommandRunsWhenTheFirstArgumentIsCli() {
        #expect(AppDelegate.isCommandLine(arguments: ["/x/ColimaBar", "--cli", "status"]))
        #expect(AppDelegate.isCommandLine(arguments: ["/x/ColimaBar", "--cli"]))
        #expect(!AppDelegate.isCommandLine(arguments: ["/x/ColimaBar"]))
        #expect(!AppDelegate.isCommandLine(arguments: []))
        #expect(!AppDelegate.isCommandLine(arguments: ["/x/ColimaBar", "--window", "--cli"]))
        #expect(!AppDelegate.isCommandLine(arguments: ["--cli", "/x/ColimaBar"]))  // the program name comes first
    }

    @Test func theCommandIsADebugRun() {
        #expect(AppDelegate.isDebugRun(arguments: ["/x/ColimaBar", "--cli", "doctor"]))
    }

    @Test func theDebugFlagsMakeADebugRun() {
        for flag in ["--snapshot", "--popover", "--notify-test", "--diagnostics"] {
            #expect(AppDelegate.isDebugRun(arguments: ["/x/ColimaBar", flag]))
        }
        #expect(!AppDelegate.isDebugRun(arguments: ["/x/ColimaBar"]))
        #expect(!AppDelegate.isDebugRun(arguments: ["/x/ColimaBar", "--window", "--replace"]))
    }
}
