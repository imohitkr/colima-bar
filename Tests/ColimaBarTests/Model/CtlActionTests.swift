import Foundation
import Testing

@testable import ColimaBar

@Suite struct CtlActionTests {
    /// The top-level `case "$1" in` labels of scripts/colima-ctl.sh.
    private func scriptActions() throws -> Set<String> {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let script = try String(
            contentsOf: root.appendingPathComponent("scripts/colima-ctl.sh"), encoding: .utf8)
        let lines = script.components(separatedBy: "\n")
        let start = try #require(lines.firstIndex(of: #"case "$1" in"#))
        let end = try #require(lines[start...].firstIndex(of: "esac"))
        var labels: Set<String> = []
        // Top-level labels have a two-space indent: "  start)" or "  ctr-rm)  ...".
        for line in lines[start..<end] where line.hasPrefix("  ") && !line.hasPrefix("   ") {
            guard let paren = line.firstIndex(of: ")") else { continue }
            let label = line.dropFirst(2)[..<paren]
            guard label.allSatisfy({ $0.isLowercase || $0.isNumber || $0 == "-" || $0 == "|" }) else { continue }
            for l in label.split(separator: "|") { labels.insert(String(l)) }
        }
        return labels
    }

    @Test func everyActionIsACaseInTheScript() throws {
        let labels = try scriptActions()
        #expect(labels.contains("start") && labels.contains("prune"))  // the parser found the labels
        for a in CtlAction.allCases {
            #expect(labels.contains(a.rawValue), "colima-ctl.sh has no case for \(a.rawValue)")
        }
    }

    /// The top-level actions of scripts/colima-ctl.sh that call `confirm`.
    private func scriptActionsWithADialog() throws -> Set<String> {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let script = try String(
            contentsOf: root.appendingPathComponent("scripts/colima-ctl.sh"), encoding: .utf8)
        let lines = script.components(separatedBy: "\n")
        let start = try #require(lines.firstIndex(of: #"case "$1" in"#))
        let end = try #require(lines[start...].firstIndex(of: "esac"))
        var current: [String] = []
        var found: Set<String> = []
        for line in lines[start..<end] {
            if line.hasPrefix("  "), !line.hasPrefix("   "), let paren = line.firstIndex(of: ")") {
                let label = line.dropFirst(2)[..<paren]
                // "a|b)" names two actions. Any other label form ends the last action.
                current =
                    label.allSatisfy({ $0.isLowercase || $0.isNumber || $0 == "-" || $0 == "|" })
                    ? label.split(separator: "|").map(String.init) : []
            }
            if line.contains("confirm \"") { found.formUnion(current) }
        }
        return found
    }

    /// Each script case with a dialog asks while the VM runs. Some ask only
    /// then, so the running list must equal the script list.
    @Test func actionsWithADialogMatchTheScript() throws {
        let script = try scriptActionsWithADialog()
        #expect(script.contains("prune"))  // the parser found the dialogs
        let running = Set(CtlAction.allCases.filter { $0.showsDialog(running: true) }.map(\.rawValue))
        #expect(running == script)
        let stopped = Set(CtlAction.allCases.filter { $0.showsDialog(running: false) }.map(\.rawValue))
        #expect(stopped.isSubset(of: script))
    }

    @Test func aStoppedVMSavesSettingsWithNoDialog() {
        for a in [CtlAction.resources, .rosetta, .k8s] {
            #expect(a.showsDialog(running: true), "\(a.rawValue)")
            #expect(!a.showsDialog(running: false), "\(a.rawValue)")
        }
        // A grow becomes permanent at the next start, and a shrink deletes data.
        for a in [CtlAction.disk, .diskShrink, .profileDelete, .prune] {
            #expect(a.showsDialog(running: false), "\(a.rawValue)")
        }
        #expect(!CtlAction.start.showsDialog(running: false))
    }

    @Test func onlyActionsWithAStateDependentDialogSendTheExpectedState() {
        let checks = Set(CtlAction.allCases.filter(\.checksExpectedState))
        #expect(checks == [.resources, .rosetta, .k8s])
    }

    @Test func theEnvironmentHasTheExpectedStateOnlyWhenTheActionChecksIt() {
        let base = ["COLIMABAR_PROFILE": "work", "COLIMABAR_APP": "1"]
        #expect(
            CtlAction.resources.environment(profile: "work", expectRunning: true)
                == base.merging(["COLIMABAR_EXPECT_RUNNING": "1"]) { $1 })
        #expect(
            CtlAction.rosetta.environment(profile: "work", expectRunning: false)
                == base.merging(["COLIMABAR_EXPECT_RUNNING": "0"]) { $1 })
        #expect(CtlAction.k8s.environment(profile: "work", expectRunning: nil) == base)
        // A disk change asks in both states, so the state does not matter.
        #expect(CtlAction.disk.environment(profile: "work", expectRunning: false) == base)
        #expect(CtlAction.start.environment(profile: "work", expectRunning: true) == base)
    }

    @Test func diskActionsAreUrgent() {
        let disk: Set<CtlAction> = [
            .imageRemove, .volumeRemove, .prune, .imagePull, .containerRemove, .stopAll, .diskShrink,
        ]
        for a in CtlAction.allCases { #expect(a.changesDisk == disk.contains(a), "\(a.rawValue)") }
    }

    @Test func vmActionsShowABusyLabel() {
        let vm: Set<CtlAction> = [
            .start, .stop, .restart, .resources, .rosetta, .k8s, .disk, .diskShrink, .autoStop, .profileCreate,
            .profileDelete,
        ]
        for a in CtlAction.allCases {
            #expect(a.isVMAction == vm.contains(a), "\(a.rawValue)")
            #expect((a.busyLabel(running: true) != nil) == vm.contains(a), "\(a.rawValue)")
            #expect((a.busyLabel(running: false) != nil) == vm.contains(a), "\(a.rawValue)")
        }
        #expect(CtlAction.start.busyLabel(running: false) == "Starting")
        #expect(CtlAction.autoStop.busyLabel(running: true) == "Stopping")
        #expect(CtlAction.disk.busyLabel(running: true) == "Restarting")
        #expect(CtlAction.diskShrink.busyLabel(running: true) == "Shrinking disk")
        #expect(CtlAction.diskShrink.busyLabel(running: false) == "Shrinking disk")
        #expect(CtlAction.profileCreate.busyLabel(running: false) == "Creating")
        #expect(CtlAction.profileDelete.busyLabel(running: false) == "Deleting")
    }

    @Test func aConfigEditOfAStoppedVMShowsSaving() {
        for a in [CtlAction.resources, .rosetta, .k8s, .disk] {
            #expect(a.editsConfigWhenStopped, "\(a.rawValue)")
            #expect(a.busyLabel(running: false) == "Saving", "\(a.rawValue)")
            #expect(a.busyLabel(running: true) == "Restarting", "\(a.rawValue)")
        }
        #expect(!CtlAction.diskShrink.editsConfigWhenStopped)
    }

    @Test func profileActionsMatchTheScriptLabels() throws {
        #expect(CtlAction.profileCreate.rawValue == "profile-create")
        #expect(CtlAction.profileDelete.rawValue == "profile-delete")
        let labels = try scriptActions()
        #expect(labels.contains("profile-create") && labels.contains("profile-delete"))
    }

    @Test func diskShrinkMatchesTheScriptLabel() throws {
        #expect(CtlAction.diskShrink.rawValue == "disk-shrink")
        #expect(try scriptActions().contains("disk-shrink"))
    }
}
