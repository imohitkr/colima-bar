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
        for a in [CtlAction.resources, .rosetta, .k8s, .vmConfig] {
            #expect(a.showsDialog(running: true), "\(a.rawValue)")
            #expect(!a.showsDialog(running: false), "\(a.rawValue)")
        }
        // A grow becomes permanent at the next start, and a shrink deletes data.
        for a in [CtlAction.disk, .diskShrink, .vmRecreate, .profileDelete, .prune] {
            #expect(a.showsDialog(running: false), "\(a.rawValue)")
        }
        #expect(!CtlAction.start.showsDialog(running: false))
    }

    @Test func onlyActionsWithAStateDependentDialogSendTheExpectedState() {
        let checks = Set(CtlAction.allCases.filter(\.checksExpectedState))
        #expect(checks == [.resources, .rosetta, .k8s, .vmConfig])
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
            .vmRecreate, .composePull, .composeDown, .autoPrune,
        ]
        for a in CtlAction.allCases { #expect(a.changesDisk == disk.contains(a), "\(a.rawValue)") }
    }

    @Test func actionsThatStopContainersHoldContainerAlerts() {
        let stops: Set<CtlAction> = [
            .stop, .restart, .resources, .rosetta, .k8s, .disk, .vmConfig, .diskShrink, .vmRecreate, .autoStop, .repair,
            .stopAll, .profileDelete,
        ]
        for a in CtlAction.allCases { #expect(a.stopsContainers == stops.contains(a), "\(a.rawValue)") }
        for a in [CtlAction.composeUp, .imagePull, .diskTrim, .prune, .ssh] { #expect(!a.stopsContainers) }
    }

    @Test func cleanupActionsAreNoVMActions() {
        for a in [CtlAction.logTruncate, .diskTrim, .autoPrune] {
            #expect(!a.isVMAction, "\(a.rawValue)")
            #expect(a.busyLabel(running: true) == nil, "\(a.rawValue)")
            #expect(!a.checksExpectedState, "\(a.rawValue)")
        }
    }

    @Test func onlyEmptyingALogAsks() {
        #expect(CtlAction.logTruncate.showsDialog(running: true))
        #expect(CtlAction.logTruncate.showsDialog(running: false))
        for a in [CtlAction.diskTrim, .autoPrune] {
            #expect(!a.showsDialog(running: true), "\(a.rawValue)")
            #expect(!a.showsDialog(running: false), "\(a.rawValue)")
        }
    }

    @Test func vmActionsShowABusyLabel() {
        let vm: Set<CtlAction> = [
            .start, .stop, .restart, .resources, .rosetta, .k8s, .disk, .vmConfig, .diskShrink, .vmRecreate,
            .autoStop, .profileCreate, .profileDelete, .repair,
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
        #expect(CtlAction.vmRecreate.busyLabel(running: true) == "Changing VM type")
        #expect(CtlAction.vmRecreate.busyLabel(running: false) == "Changing VM type")
        #expect(CtlAction.profileCreate.busyLabel(running: false) == "Creating")
        #expect(CtlAction.profileDelete.busyLabel(running: false) == "Deleting")
        #expect(CtlAction.repair.busyLabel(running: true) == "Repairing")
        #expect(CtlAction.repair.busyLabel(running: false) == "Repairing")
    }

    @Test func repairAsksInBothStatesAndStaleFilesIsReadOnly() throws {
        #expect(CtlAction.repair.showsDialog(running: true) && CtlAction.repair.showsDialog(running: false))
        #expect(!CtlAction.repair.checksExpectedState)
        #expect(CtlAction.repair.isVMAction)
        #expect(!CtlAction.staleFiles.isVMAction)
        #expect(!CtlAction.staleFiles.showsDialog(running: true))
        #expect(CtlAction.staleFiles.rawValue == "stale-files")
        let labels = try scriptActions()
        #expect(labels.contains("repair") && labels.contains("stale-files"))
    }

    @Test func aConfigEditOfAStoppedVMShowsSaving() {
        for a in [CtlAction.resources, .rosetta, .k8s, .disk, .vmConfig] {
            #expect(a.editsConfigWhenStopped, "\(a.rawValue)")
            #expect(a.busyLabel(running: false) == "Saving", "\(a.rawValue)")
            #expect(
                a.busyLabel(running: true) == (a == .vmConfig ? "Applying VM settings" : "Restarting"), "\(a.rawValue)")
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

    @Test func vmRecreateMatchesTheScriptAndAsksInBothStates() throws {
        #expect(CtlAction.vmRecreate.rawValue == "vm-recreate")
        #expect(try scriptActions().contains("vm-recreate"))
        #expect(CtlAction.vmRecreate.showsDialog(running: true) && CtlAction.vmRecreate.showsDialog(running: false))
        #expect(!CtlAction.vmRecreate.checksExpectedState)
        #expect(CtlAction.vmRecreate.isVMAction && CtlAction.vmRecreate.stopsContainers)
    }

    @Test func onlyAVMTypeChangeGetsThirtyMinutes() {
        for a in CtlAction.allCases {
            #expect(a.timeout == (a == .vmRecreate ? 1800 : 900), "\(a.rawValue)")
        }
    }

    // MARK: upgrade guard

    @Test func onlyAStartThatLeavesAFreshVMCounts() {
        #expect(CtlAction.start.startsVM(running: false))
        #expect(!CtlAction.start.startsVM(running: true))
        for a in [CtlAction.restart, .repair, .profileCreate, .diskShrink, .vmRecreate] {
            #expect(a.startsVM(running: true) && a.startsVM(running: false), "\(a.rawValue)")
        }
        for a in [CtlAction.resources, .rosetta, .k8s, .disk, .vmConfig] {
            #expect(a.startsVM(running: true), "\(a.rawValue)")
            #expect(!a.startsVM(running: false), "\(a.rawValue)")
        }
        for a in [CtlAction.stop, .autoStop, .profileDelete, .prune, .logs] {
            #expect(!a.startsVM(running: true) && !a.startsVM(running: false), "\(a.rawValue)")
        }
    }

    @Test func warningActionsAreStartsThatTheUserBegins() {
        for a in CtlAction.allCases {
            for running in [true, false] where a.warnsAfterUpgrade(running: running) {
                #expect(a.startsVM(running: running), "\(a.rawValue)")
            }
        }
        #expect(CtlAction.start.warnsAfterUpgrade(running: false))
        #expect(CtlAction.restart.warnsAfterUpgrade(running: true))
        #expect(CtlAction.resources.warnsAfterUpgrade(running: true))
        #expect(!CtlAction.resources.warnsAfterUpgrade(running: false))
        #expect(CtlAction.vmConfig.warnsAfterUpgrade(running: true))
        #expect(!CtlAction.vmConfig.warnsAfterUpgrade(running: false))
        #expect(CtlAction.vmRecreate.warnsAfterUpgrade(running: true))
        #expect(CtlAction.vmRecreate.warnsAfterUpgrade(running: false))
        for a in [CtlAction.repair, .diskShrink, .profileCreate] {
            #expect(!a.warnsAfterUpgrade(running: true) && !a.warnsAfterUpgrade(running: false), "\(a.rawValue)")
        }
    }

    @Test func theUpgradeNoteGoesInTheEnvironmentOnlyForWarningActions() {
        let up = (
            note: "Colima changed.",
            releaseNotes: [URL(string: "https://github.com/abiosoft/colima/releases/tag/v0.11.0")!]
        )
        let start = CtlAction.start.environment(profile: "work", expectRunning: false, upgrade: up)
        #expect(start["COLIMABAR_UPGRADE_NOTE"] == "Colima changed.")
        #expect(start["COLIMABAR_RELEASE_NOTES"] == "https://github.com/abiosoft/colima/releases/tag/v0.11.0")
        let stopped = CtlAction.resources.environment(profile: "work", expectRunning: false, upgrade: up)
        #expect(stopped["COLIMABAR_UPGRADE_NOTE"] == nil)
        let repair = CtlAction.repair.environment(profile: "work", expectRunning: true, upgrade: up)
        #expect(repair["COLIMABAR_UPGRADE_NOTE"] == nil)
        let none = CtlAction.start.environment(profile: "work", expectRunning: false)
        #expect(none["COLIMABAR_UPGRADE_NOTE"] == nil && none["COLIMABAR_RELEASE_NOTES"] == nil)
    }

    /// The top-level actions of scripts/colima-ctl.sh that call `upgrade_confirm`.
    private func scriptActionsWithAnUpgradeDialog() throws -> Set<String> {
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
                current =
                    label.allSatisfy({ $0.isLowercase || $0.isNumber || $0 == "-" || $0 == "|" })
                    ? label.split(separator: "|").map(String.init) : []
            }
            if line.contains("upgrade_confirm ||") { found.formUnion(current) }
        }
        return found
    }

    @Test func actionsThatWarnAfterAnUpgradeMatchTheScript() throws {
        let script = try scriptActionsWithAnUpgradeDialog()
        #expect(script.contains("start") && script.contains("disk"))  // the parser found the calls
        let warns = Set(
            CtlAction.allCases.filter { $0.warnsAfterUpgrade(running: true) || $0.warnsAfterUpgrade(running: false) }
                .map(\.rawValue))
        #expect(warns == script)
    }

    @Test func theVMSettingsActionMatchesTheScriptAndAsksOnlyForARunningVM() throws {
        #expect(CtlAction.vmConfig.rawValue == "vm-config")
        #expect(try scriptActions().contains("vm-config"))
        #expect(CtlAction.vmConfig.isVMAction)
        #expect(CtlAction.vmConfig.showsDialog(running: true) && !CtlAction.vmConfig.showsDialog(running: false))
        #expect(!CtlAction.vmConfig.changesDisk)
        let stopped = CtlAction.vmConfig.environment(profile: "work", expectRunning: false)
        #expect(stopped["COLIMABAR_EXPECT_RUNNING"] == "0")
    }

    @Test func composeActionsMatchTheScriptLabels() throws {
        let labels = try scriptActions()
        for a in [CtlAction.composePull, .composeUp, .composeDown] {
            #expect(labels.contains(a.rawValue), "\(a.rawValue)")
            #expect(!a.isVMAction && a.busyLabel(running: true) == nil && a.busyLabel(running: false) == nil)
            #expect(!a.checksExpectedState && !a.warnsAfterUpgrade(running: true))
        }
        #expect(CtlAction.composePull.rawValue == "compose-pull")
        #expect(CtlAction.composeUp.rawValue == "compose-up")
        #expect(CtlAction.composeDown.rawValue == "compose-down")
    }

    @Test func onlyComposeDownAsksFirst() {
        for running in [true, false] {
            #expect(CtlAction.composeDown.showsDialog(running: running))
            #expect(!CtlAction.composePull.showsDialog(running: running))
            #expect(!CtlAction.composeUp.showsDialog(running: running))
        }
    }

    @Test func composeActionsNeedNoExpectedState() {
        let env = CtlAction.composeDown.environment(profile: "work", expectRunning: nil)
        #expect(env == ["COLIMABAR_PROFILE": "work", "COLIMABAR_APP": "1"])
    }
}
