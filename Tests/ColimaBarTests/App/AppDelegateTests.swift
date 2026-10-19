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

    @Test func theShortcutActionFollowsTheTableForAllInputs() {
        typealias Row = (modal: Bool, popover: Bool, open: Bool, front: Bool, action: ShortcutAction)
        let table: [Row] = [
            (false, false, false, false, .reveal),
            (false, false, false, true, .reveal),
            (false, false, true, false, .showWindow),
            (false, false, true, true, .closeWindow),
            (false, true, false, false, .closePopover),
            (false, true, false, true, .closePopover),
            (false, true, true, false, .closePopover),
            (false, true, true, true, .closePopover),
        ]
        let modalRows: [Row] = table.map { (true, $0.popover, $0.open, $0.front, .nothing) }
        for row in table + modalRows {
            let action = AppDelegate.shortcutAction(
                modal: row.modal, popoverShown: row.popover, windowOpen: row.open, windowFront: row.front)
            #expect(action == row.action, "\(row)")
        }
    }
}
