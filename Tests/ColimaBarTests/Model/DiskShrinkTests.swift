import Foundation
import Testing

@testable import ColimaBar

@Suite struct DiskShrinkTests {
    @Test func offersOnlySmallerSizes() {
        #expect(DiskShrink.options(current: 100) == [20, 40, 60, 80])
        #expect(DiskShrink.options(current: 60) == [20, 40])
        #expect(DiskShrink.options(current: 20) == [])
        #expect(DiskShrink.options(current: 0) == [])  // VM facts not loaded yet
    }

    @Test func rejectsSizesBelowTheMinimumOrNotSmaller() {
        #expect(DiskShrink.isValid(10, current: 100))
        #expect(!DiskShrink.isValid(9, current: 100))
        #expect(!DiskShrink.isValid(100, current: 100))
        #expect(!DiskShrink.isValid(120, current: 100))
        #expect(!DiskShrink.isValid(10, current: 10))
    }

    @Test func needsTheExactProfileName() {
        #expect(DiskShrink.confirms(typed: "default", profile: "default"))
        #expect(DiskShrink.confirms(typed: " work ", profile: "work"))
        #expect(!DiskShrink.confirms(typed: "Default", profile: "default"))
        #expect(!DiskShrink.confirms(typed: "defaul", profile: "default"))
        #expect(!DiskShrink.confirms(typed: "", profile: ""))
    }

    @Test func warningListsWhatIsDeleted() {
        let usage = [
            DFRow(type: "Images", count: 3, size: 2 * 1_073_741_824, reclaimable: 0),
            DFRow(type: "Volumes", count: 1, size: 1_073_741_824, reclaimable: 0),
        ]
        let text = DiskShrink.warning(
            profile: "work", from: 100, to: 40, usage: usage, kubernetes: true, running: true)
        #expect(text.contains("100 GB disk"))
        #expect(text.contains("starts the VM again with an empty 40 GB disk"))
        #expect(!text.contains("stops it again"))
        #expect(text.contains("• Images: 3, 2.0 GB"))
        #expect(text.contains("• Volumes: 1, 1.0 GB"))
        #expect(text.contains("Total: 3.0 GB"))
        #expect(text.contains("Kubernetes"))
        #expect(text.hasSuffix("type the profile name: work"))
    }

    @Test func warningForAStoppedVMSaysEverythingIsDeleted() {
        let text = DiskShrink.warning(
            profile: "default", from: 60, to: 20, usage: [], kubernetes: false, running: false)
        #expect(text.contains("All containers, images, volumes and build cache are deleted"))
        #expect(!text.contains("Kubernetes"))
    }

    @Test func warningForAStoppedVMSaysTheVMStopsAgain() {
        let text = DiskShrink.warning(
            profile: "work", from: 100, to: 40, usage: [], kubernetes: true, running: false)
        #expect(text.contains("Colima starts the VM once to create the new 40 GB disk, then stops it again."))
        #expect(!text.contains("starts the VM again"))
        #expect(text.contains("Kubernetes"))
        #expect(text.hasSuffix("type the profile name: work"))
    }

    @Test func warningForARunningVMNamesTheVolumesToBackUp() {
        let text = DiskShrink.warning(
            profile: "work", from: 100, to: 40, usage: [], kubernetes: false, running: true,
            volumes: ["a", "b", "c"])
        #expect(text.contains("To keep volume data, back up the volumes first: a, b, c."))
        #expect(text.hasSuffix("type the profile name: work"))
    }

    @Test func warningForARunningVMWithoutVolumesHasNoBackupLine() {
        let text = DiskShrink.warning(
            profile: "work", from: 100, to: 40, usage: [], kubernetes: false, running: true, volumes: [])
        #expect(!text.contains("To keep volume data"))
    }

    @Test func warningForAStoppedVMTellsToStartAndBackUp() {
        let text = DiskShrink.warning(
            profile: "work", from: 100, to: 40, usage: [], kubernetes: false, running: false)
        #expect(text.contains("To keep volume data, start the VM and back up the volumes first."))
    }

    @Test func theVolumeListStopsAtEightNames() {
        let names = (1...11).map { "vol\($0)" }
        let line = DiskShrink.backupAdvice(running: true, volumes: names)
        #expect(
            line
                == "To keep volume data, back up the volumes first: vol1, vol2, vol3, vol4, vol5, vol6, vol7, vol8 and 3 more."
        )
    }

    @Test func eightVolumesAreAllListed() {
        let names = (1...8).map { "v\($0)" }
        #expect(DiskShrink.backupAdvice(running: true, volumes: names)?.hasSuffix("v7, v8.") == true)
    }

    /// colima-ctl.sh checks the same minimum, so the menu never offers a
    /// size that the script rejects.
    @Test func minimumMatchesTheScript() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let script = try String(
            contentsOf: root.appendingPathComponent("scripts/colima-ctl.sh"), encoding: .utf8)
        let line = try #require(script.components(separatedBy: "\n").first { $0.hasPrefix("MIN_DISK=") })
        #expect(Int(line.dropFirst("MIN_DISK=".count)) == DiskShrink.minimumGB)
    }

    @Test func theDestructiveButtonShrinksOnlyWithTheTypedName() {
        #expect(DiskShrink.answer(clicked: 0, typedOK: true, offersBackup: false) == .shrink)
        #expect(DiskShrink.answer(clicked: 0, typedOK: true, offersBackup: true) == .shrink)
        #expect(DiskShrink.answer(clicked: 0, typedOK: false, offersBackup: true) == .cancel)
    }

    @Test func theSecondButtonBacksUpOnlyWhenTheAlertOffersIt() {
        #expect(DiskShrink.answer(clicked: 1, typedOK: false, offersBackup: true) == .backUpVolumes)
        #expect(DiskShrink.answer(clicked: 1, typedOK: true, offersBackup: true) == .backUpVolumes)
        #expect(DiskShrink.answer(clicked: 1, typedOK: true, offersBackup: false) == .cancel)
    }

    @Test func theLastButtonCancels() {
        #expect(DiskShrink.answer(clicked: 2, typedOK: true, offersBackup: true) == .cancel)
        #expect(DiskShrink.answer(clicked: 1, typedOK: true, offersBackup: false) == .cancel)
    }
}
