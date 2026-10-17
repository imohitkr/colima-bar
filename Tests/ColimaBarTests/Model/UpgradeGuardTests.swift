import Foundation
import Testing

@testable import ColimaBar

@Suite struct UpgradeGuardTests {
    private let last = ToolVersions(colima: "0.10.3", lima: "2.2.1", macOS: "15.6.1")

    @Test func noRecordGivesNoWarning() {
        let now = ToolVersions(colima: "0.11.0", lima: "2.3.0")
        #expect(UpgradeGuard.riskyChanges(last: nil, now: now).isEmpty)
    }

    @Test func onlyRiskyChangesWarn() {
        let patch = ToolVersions(colima: "0.10.4", lima: "2.2.2", macOS: "26.0.0")
        #expect(UpgradeGuard.riskyChanges(last: last, now: patch).isEmpty)
        let minor = ToolVersions(colima: "0.11.0", lima: "2.2.1", macOS: "15.6.1")
        #expect(UpgradeGuard.riskyChanges(last: last, now: minor).map(\.tool) == [.colima])
    }

    @Test func noteNamesTheChangesAndTheProfile() {
        let now = ToolVersions(colima: "0.11.0", lima: "2.3.0")
        let text = UpgradeGuard.note(profile: "work", changes: UpgradeGuard.riskyChanges(last: last, now: now))
        #expect(
            text
                == "Colima 0.10.3 → 0.11.0 and Lima 2.2.1 → 2.3.0 since the last good start of profile 'work'. A new version can change the VM disk. Back up important volumes first, or read the release notes. Continue?"
        )
    }

    @Test func autoStartTextShowsTheNewAndTheOldVersion() {
        let now = ToolVersions(colima: "0.11.0", lima: "2.2.1")
        let text = UpgradeGuard.autoStartText(
            profile: "work", changes: UpgradeGuard.riskyChanges(last: last, now: now))
        #expect(
            text == "Auto-start started profile work with Colima 0.11.0 (before: 0.10.3). Click for the release notes.")
    }

    @Test func releaseNotesPointToTheTagsOfColimaAndLima() {
        let now = ToolVersions(colima: "0.11.0-3-gabc", lima: "v2.3.0")
        let urls = UpgradeGuard.releaseNotes(UpgradeGuard.riskyChanges(last: last, now: now)).map(\.absoluteString)
        #expect(
            urls == [
                "https://github.com/abiosoft/colima/releases/tag/v0.11.0",
                "https://github.com/lima-vm/lima/releases/tag/v2.3.0",
            ])
    }

    @Test func releaseNotesLeaveOutMacOS() {
        let change = VersionChange(tool: .macOS, from: "15.6", to: "26.0.0", kind: .major)
        #expect(UpgradeGuard.releaseNotes([change]).isEmpty)
    }

    @Test func aRecordNeedsKnownColimaAndLimaVersions() {
        #expect(UpgradeGuard.canSave(ToolVersions(colima: "0.10.3", lima: "2.2.1")))
        #expect(!UpgradeGuard.canSave(ToolVersions(colima: "0.10.3", lima: nil)))
        #expect(!UpgradeGuard.canSave(ToolVersions(colima: "unknown", lima: "2.2.1")))
        #expect(!UpgradeGuard.canSave(ToolVersions(colima: nil, lima: nil, macOS: "15.6.1")))
    }

    @Test func unknownCurrentVersionsGiveNoRiskyChange() {
        // Lima timed out, Colima is new: ColimaBar could not save, so it must not warn.
        let now = ToolVersions(colima: "0.11.0", lima: nil)
        #expect(UpgradeGuard.riskyChanges(last: last, now: now).isEmpty)
        #expect(UpgradeGuard.autoStartNotice(profile: "work", last: last, now: now) == nil)
    }

    @Test func anIncompleteRecordGivesNoRiskyChange() {
        let now = ToolVersions(colima: "0.11.0", lima: "2.3.0")
        #expect(UpgradeGuard.riskyChanges(last: ToolVersions(colima: "0.10.3"), now: now).isEmpty)
        #expect(UpgradeGuard.riskyChanges(last: ToolVersions(colima: "0.10.3", lima: "x"), now: now).isEmpty)
    }

    @Test func aWarningNeedsAWarningActionAndARiskyChange() throws {
        let now = ToolVersions(colima: "0.11.0", lima: "2.2.1")
        let w = try #require(
            UpgradeGuard.warning(action: .start, running: false, profile: "work", last: last, now: now))
        #expect(w.note.hasPrefix("Colima 0.10.3 → 0.11.0 since"))
        #expect(w.releaseNotes.map(\.absoluteString) == ["https://github.com/abiosoft/colima/releases/tag/v0.11.0"])
        // Not a warning action, or the VM is in the wrong state for it.
        #expect(UpgradeGuard.warning(action: .repair, running: true, profile: "work", last: last, now: now) == nil)
        #expect(UpgradeGuard.warning(action: .start, running: true, profile: "work", last: last, now: now) == nil)
        #expect(UpgradeGuard.warning(action: .resources, running: false, profile: "work", last: last, now: now) == nil)
        // No record, no probe result, or only a patch change.
        #expect(UpgradeGuard.warning(action: .start, running: false, profile: "work", last: nil, now: now) == nil)
        #expect(UpgradeGuard.warning(action: .start, running: false, profile: "work", last: last, now: nil) == nil)
        let patch = ToolVersions(colima: "0.10.4", lima: "2.2.1")
        #expect(UpgradeGuard.warning(action: .start, running: false, profile: "work", last: last, now: patch) == nil)
    }

    @Test func theAutoStartNoticeLinksTheFirstReleasePage() throws {
        let now = ToolVersions(colima: "0.11.0", lima: "2.3.0")
        let n = try #require(UpgradeGuard.autoStartNotice(profile: "work", last: last, now: now))
        #expect(n.text.hasPrefix("Auto-start started profile work with Colima 0.11.0 (before: 0.10.3)"))
        #expect(n.url?.absoluteString == "https://github.com/abiosoft/colima/releases/tag/v0.11.0")
    }

    @Test func theNoticeIsQuietOnceTheVersionsAreRecorded() {
        let now = ToolVersions(colima: "0.11.0", lima: "2.3.0")
        #expect(UpgradeGuard.autoStartNotice(profile: "work", last: now, now: now) == nil)
    }

    @Test func theStartMarkerIsALineOfItsOwn() {
        #expect(UpgradeGuard.started(in: "x\nCOLIMABAR_STARTED\n"))
        #expect(!UpgradeGuard.started(in: ""))
        #expect(!UpgradeGuard.started(in: "COLIMABAR_NOTIFY:COLIMABAR_STARTED"))
    }
}
