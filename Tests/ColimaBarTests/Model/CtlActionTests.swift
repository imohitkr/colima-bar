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
            #expect((a.busyLabel != nil) == vm.contains(a), "\(a.rawValue)")
        }
        #expect(CtlAction.start.busyLabel == "Starting")
        #expect(CtlAction.autoStop.busyLabel == "Stopping")
        #expect(CtlAction.disk.busyLabel == "Restarting")
        #expect(CtlAction.diskShrink.busyLabel == "Shrinking disk")
        #expect(CtlAction.profileCreate.busyLabel == "Creating")
        #expect(CtlAction.profileDelete.busyLabel == "Deleting")
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
