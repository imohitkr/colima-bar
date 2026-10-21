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
