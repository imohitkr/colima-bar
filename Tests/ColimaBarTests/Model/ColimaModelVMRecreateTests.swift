import Foundation
import Testing

@testable import ColimaBar

@Suite @MainActor struct ColimaModelVMRecreateTests {
    // MARK: Rules

    @Test func aChangeNeedsANormalRunNoOtherActionAndAConfigFile() {
        func may(
            debug: Bool = false, busy: Bool = false, transferring: Bool = false, recreating: Bool = false,
            config: Bool = true
        ) -> Bool {
            ColimaModel.mayRecreate(
                isDebug: debug, busy: busy, transferring: transferring, recreating: recreating, hasConfig: config)
        }
        #expect(may())
        #expect(!may(debug: true))
        #expect(!may(busy: true))
        #expect(!may(transferring: true))
        #expect(!may(recreating: true))
        #expect(!may(config: false))
    }

    @Test func aDebugRunStartsNothingAndWritesNoJournal() {
        let model = ColimaModel(profile: "recreate-test-profile", readOnly: true)
        #expect(!model.canRecreate)
        #expect(model.recreateBlockReason == Help.doctorDebug)
        model.startRecreate(vmType: "qemu", mountType: "sshfs", backUp: false, saveImages: false, parent: nil)
        #expect(model.recreate == nil)
        model.dismissRecreate("recreate-test-profile")
        model.resumeRecreate("recreate-test-profile", folder: URL(fileURLWithPath: "/tmp"))
        #expect(model.recreate == nil)
    }

    @Test func aProfileWithoutAConfigFileGivesItsOwnReason() {
        let model = ColimaModel(profile: "recreate-test-profile")
        #expect(model.recreateBlockReason == Help.recreateNoConfig)
    }

    @Test func aChangeCancelsOnlyInAStepThatCanStop() {
        let model = ColimaModel(profile: "recreate-test-profile")
        model.setRecreate(VMRecreateProgress(profile: "recreate-test-profile", step: .backingUp))
        #expect(model.recreate?.step == .backingUp)
        model.cancelRecreate()
        #expect(model.recreate?.isCancelling == true)
        // The script and the wait for Docker cannot be cancelled.
        model.setRecreate(VMRecreateProgress(profile: "recreate-test-profile", step: .recreating))
        model.cancelRecreate()
        #expect(model.recreate?.isCancelling == false)
    }

    @Test func aVolumeTransferShowsInTheStripOfAChange() {
        let model = ColimaModel(profile: "recreate-test-profile", readOnly: true)
        model.setRecreate(VMRecreateProgress(profile: "recreate-test-profile", step: .backingUp))
        var t = VolumeTransfer(kind: .backup, volume: "pgdata", total: 100, position: 2, count: 5)
        t.bytes = 40
        model.setVolumeTransfer(t)
        let r = model.recreate
        #expect(r?.volume == "pgdata" && r?.bytes == 40 && r?.total == 100 && r?.position == 2 && r?.count == 5)
        // Other steps ignore a transfer.
        model.setRecreate(VMRecreateProgress(profile: "recreate-test-profile", step: .savingImages))
        model.setVolumeTransfer(VolumeTransfer(kind: .backup, volume: "other"))
        #expect(model.recreate?.volume == "")
    }

    // MARK: Start rules

    private func journal(
        _ profile: String, phase: VMRecreateJournal.Phase = .restore, folder: String = ""
    ) -> VMRecreateJournal {
        VMRecreateJournal(
            profile: profile, from: .init(vmType: "vz", mountType: "virtiofs"),
            to: .init(vmType: "qemu", mountType: "sshfs"), folder: folder, created: Date(), phase: phase)
    }

    private func readyModel(_ profile: String, dir: String, notes: Notes = Notes()) -> ColimaModel {
        let model = ColimaModel(profile: profile, recreateCacheDir: dir)
        model.setVMSettings(VMSettings.Read())
        model.notifySink = { notes.texts.append($0) }
        return model
    }

    /// The notifications of a model.
    final class Notes {
        var texts: [String] = []
    }

    @Test func anUnfinishedChangeBlocksANewOne() throws {
        let dir = try TempFolder()
        let p = "recreate-pending-test"
        let notes = Notes()
        let model = readyModel(p, dir: dir.path, notes: notes)
        #expect(model.canRecreate)
        model.setPendingRecreate([p: journal(p)])
        #expect(!model.canRecreate)
        #expect(model.recreateBlockReason == Help.recreatePending)
        model.startRecreate(vmType: "qemu", mountType: "sshfs", backUp: false, saveImages: false, parent: nil)
        #expect(model.recreate == nil)
        #expect(notes.texts == [Help.recreatePending])
        #expect(model.pendingRecreate[p] != nil)
        #expect(!FileManager.default.fileExists(atPath: model.recreateJournalPath(p)))
    }

    @Test func theRuleRefusesAPendingChange() {
        #expect(
            !ColimaModel.mayRecreate(
                isDebug: false, busy: false, transferring: false, recreating: false, hasConfig: true,
                hasPending: true))
    }

    @Test func aBackupChoiceThatTheVMCannotKeepIsRefusedNotDropped() throws {
        let dir = try TempFolder()
        let p = "recreate-downgrade-test"
        let notes = Notes()
        let model = readyModel(p, dir: dir.path, notes: notes)
        // The VM is stopped: no backup is possible, and the choice must not turn into "no backup".
        for (backUp, images) in [(true, false), (false, true), (true, true)] {
            model.startRecreate(
                vmType: "qemu", mountType: "sshfs", backUp: backUp, saveImages: images,
                parent: URL(fileURLWithPath: dir.path))
            #expect(model.recreate == nil)
            #expect(!model.hasActionInFlight)
        }
        #expect(notes.texts.count == 3 && notes.texts.allSatisfy { $0.hasPrefix("ColimaBar cannot back up now") })
    }

    @Test func everyActionIsRefusedWhileAChangeRuns() {
        let p = "recreate-block-test"
        let model = ColimaModel(profile: p)
        var told: [String] = []
        model.notifySink = { told.append($0) }
        model.setRecreate(VMRecreateProgress(profile: p, step: .backingUp))
        for action in [CtlAction.restart, .stop, .start, .vmRecreate, .repair] {
            model.run(action, profile: p)
            model.run(action, profile: "another-profile")
        }
        #expect(model.busy == nil)
        #expect(!model.hasActionInFlight)
        #expect(told.count == 10 && told.allSatisfy { $0 == Help.recreateBusy })
    }

    // MARK: Journal files

    @Test func aJournalIsWrittenToTheCacheFolderWithTheMode0600() throws {
        let dir = try TempFolder()
        let p = "recreate-write-test"
        let model = ColimaModel(profile: p, recreateCacheDir: dir.path + "/cache")
        #expect(model.writeRecreateJournal(journal(p, phase: .backup)))
        let path = model.recreateJournalPath(p)
        var st = stat()
        stat(path, &st)
        #expect(st.st_mode & 0o777 == 0o600)
        #expect(VMRecreateJournal.load(try Data(contentsOf: URL(fileURLWithPath: path)))?.phase == .backup)
    }

    @Test func aJournalThatCannotBeWrittenGivesFalse() throws {
        let dir = try TempFolder()
        // A regular file where the cache folder should be.
        try "x".write(toFile: dir.path + "/file", atomically: true, encoding: .utf8)
        let model = ColimaModel(profile: "recreate-fail-test", recreateCacheDir: dir.path + "/file/cache")
        #expect(!model.writeRecreateJournal(journal("recreate-fail-test")))
    }

    @Test func theCopyInTheBackupFolderNeedsTheFolderAndMakesNoNewOne() throws {
        let dir = try TempFolder()
        let p = "recreate-copy-test"
        let model = ColimaModel(profile: p, recreateCacheDir: dir.path)
        let gone = dir.path + "/stale/ColimaBar-1"
        #expect(model.writeRecreateJournal(journal(p, folder: gone)))
        #expect(!FileManager.default.fileExists(atPath: dir.path + "/stale"))
        let there = dir.path + "/ColimaBar-2"
        try FileManager.default.createDirectory(atPath: there, withIntermediateDirectories: false)
        #expect(model.writeRecreateJournal(journal(p, folder: there)))
        #expect(FileManager.default.fileExists(atPath: there + "/recreate.json"))
        try FileManager.default.removeItem(atPath: there + "/recreate.json")
        // A resume does not write the copy again.
        #expect(model.writeRecreateJournal(journal(p, folder: there), writesCopy: false))
        #expect(!FileManager.default.fileExists(atPath: there + "/recreate.json"))
    }

    @Test func aDebugRunWritesNoJournalAndReadsNone() throws {
        let dir = try TempFolder()
        let p = "recreate-debug-test"
        try journal(p).encoded().write(to: URL(fileURLWithPath: dir.path + "/recreate.\(p).json"))
        let model = ColimaModel(profile: p, readOnly: true, recreateCacheDir: dir.path)
        model.loadRecreateJournals()
        #expect(model.pendingRecreate.isEmpty)
        #expect(model.writeRecreateJournal(journal(p)))
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["recreate.\(p).json"])
    }

    @Test func aNormalRunReadsTheJournalsOfTheInjectedFolderOnly() throws {
        let dir = try TempFolder()
        let p = "recreate-load-test"
        try journal(p).encoded().write(to: URL(fileURLWithPath: dir.path + "/recreate.\(p).json"))
        let model = ColimaModel(profile: p, recreateCacheDir: dir.path)
        model.loadRecreateJournals()
        #expect(model.pendingRecreate[p]?.profile == p)
        model.dismissRecreate(p)
        #expect(model.pendingRecreate.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: dir.path + "/recreate.\(p).json"))
    }

    @Test func aJournalOfABusyProfileIsLeftOut() throws {
        let dir = try TempFolder()
        try journal("work").encoded().write(to: URL(fileURLWithPath: dir.path + "/recreate.work.json"))
        try journal("play").encoded().write(to: URL(fileURLWithPath: dir.path + "/recreate.play.json"))
        let found = ColimaModel.readRecreateJournals(in: dir.path, config: { _ in nil }, isBusy: { $0 == "work" })
        #expect(Set(found.keys) == ["play"])
    }

    @Test func aJournalWhoseNameDoesNotMatchItsProfileIsIgnored() throws {
        let dir = try TempFolder()
        try journal("work").encoded().write(to: URL(fileURLWithPath: dir.path + "/recreate.other.json"))
        try Data("not json".utf8).write(to: URL(fileURLWithPath: dir.path + "/recreate.bad.json"))
        let found = ColimaModel.readRecreateJournals(in: dir.path, config: { _ in nil }, isBusy: { _ in false })
        #expect(found.isEmpty)
    }

    @Test func theRecoveryReadsTheConfigOfTheProfile() throws {
        let dir = try TempFolder()
        try journal("work", phase: .recreate).encoded().write(
            to: URL(fileURLWithPath: dir.path + "/recreate.work.json"))
        // The file has the new types: the VM changed. The file is gone: the notice says so.
        for (text, recovery) in [
            ("vmType: qemu\nmountType: sshfs\n", VMRecreateJournal.Recovery.restorePending),
            ("vmType: vz\nmountType: virtiofs\n", .nothingChanged),
        ] {
            let found = ColimaModel.readRecreateJournals(in: dir.path, config: { _ in text }, isBusy: { _ in false })
            let j = try #require(found["work"])
            #expect(VMRecreateJournal.recovery(j, now: VMSettings.read(text), busy: false) == recovery)
        }
        let missing = ColimaModel.readRecreateJournals(in: dir.path, config: { _ in nil }, isBusy: { _ in false })
        #expect(missing["work"] != nil)
    }

    // MARK: Folder

    @Test func theBackupFolderHasTheProfileAndTheTimeAndTheMode0700() throws {
        let parent = try TempFolder()
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let tz = TimeZone(identifier: "UTC")!
        let url = try ColimaModel.makeBackupFolder(
            parent: URL(fileURLWithPath: parent.path), profile: "work", date: date, timeZone: tz
        ).get()
        #expect(url.lastPathComponent == "ColimaBar-work-20231114-221320")
        var st = stat()
        stat(url.path, &st)
        #expect(st.st_mode & 0o777 == 0o700)
    }

    @Test func aFolderThatExistsIsNeverReused() throws {
        let parent = try TempFolder()
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let tz = TimeZone(identifier: "UTC")!
        let top = URL(fileURLWithPath: parent.path)
        _ = try ColimaModel.makeBackupFolder(parent: top, profile: "work", date: date, timeZone: tz).get()
        let again = ColimaModel.makeBackupFolder(parent: top, profile: "work", date: date, timeZone: tz)
        guard case .failure(let f) = again else {
            Issue.record("the folder was reused")
            return
        }
        #expect(f == VolumeBackupRunner.exists)
    }

    @Test func anEmptyFolderGoesAwayButAFolderWithABackupStays() throws {
        let parent = try TempFolder()
        let empty = URL(fileURLWithPath: parent.path + "/empty")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: false)
        try "{}".write(to: empty.appendingPathComponent("recreate.json"), atomically: true, encoding: .utf8)
        ColimaModel.removeEmptyFolder(empty)
        #expect(!FileManager.default.fileExists(atPath: empty.path))
        let full = URL(fileURLWithPath: parent.path + "/full")
        try FileManager.default.createDirectory(at: full, withIntermediateDirectories: false)
        try "x".write(to: full.appendingPathComponent("a-1.tar"), atomically: true, encoding: .utf8)
        ColimaModel.removeEmptyFolder(full)
        #expect(FileManager.default.fileExists(atPath: full.appendingPathComponent("a-1.tar").path))
    }

    // MARK: Texts

    private let head = "The VM of profile work now uses qemu / sshfs."

    private func message(
        restop: Bool = false, restored: Int = 0, kept: Int = 0, failed: [String] = [], images: Bool = false
    ) -> String {
        ColimaModel.recreateMessage(
            head: head, folder: "ColimaBar-work-1", restop: restop, restored: restored, kept: kept, failed: failed,
            imagesLoaded: images)
    }

    @Test func theMessageSaysWhatHappenedToTheData() {
        #expect(message(kept: 2) == "\(head) Volumes and images are still there.")
        #expect(
            message(restored: 2, images: true)
                == "\(head) Restored 2 volumes and loaded the images from ColimaBar-work-1.")
        #expect(message(restored: 1) == "\(head) Restored 1 volume from ColimaBar-work-1.")
        #expect(message(images: true) == "\(head) Loaded the images from ColimaBar-work-1.")
        #expect(message(restop: true) == "\(head) It is stopped again.")
        #expect(
            message(restored: 1, failed: ["b (No space.)", "images (Docker did not answer)"])
                == "\(head) Restore failed for: b (No space.), images (Docker did not answer). The backups are in ColimaBar-work-1."
        )
    }

    @Test func theNoticeTextMatchesTheRecovery() {
        var j = VMRecreateJournal(
            profile: "work", from: .init(vmType: "vz", mountType: "virtiofs"),
            to: .init(vmType: "qemu", mountType: "sshfs"), folder: "/Users/me/ColimaBar-work-1", created: Date(),
            phase: .restore)
        #expect(
            VMRecreateNotice.text(j, .restorePending)
                == "A VM type change of profile work did not finish. The backups are in ColimaBar-work-1.")
        #expect(
            VMRecreateNotice.text(j, .nothingChanged)
                == "A VM type change of profile work stopped before it changed the VM. Nothing changed.")
        #expect(VMRecreateNotice.text(j, .configMissing).contains("~/.cache/colima-bar/colima.work.yaml.recreate"))
        j.folder = ""
        #expect(VMRecreateNotice.text(j, .restorePending) == "A VM type change of profile work did not finish.")
    }
}
