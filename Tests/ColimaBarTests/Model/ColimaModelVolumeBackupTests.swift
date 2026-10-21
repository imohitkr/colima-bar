import Foundation
import Testing

@testable import ColimaBar

@Suite @MainActor struct ColimaModelVolumeBackupTests {
    private func containers(_ json: String) throws -> [APIContainer] {
        try JSONDecoder().decode([APIContainer].self, from: Data(json.utf8))
    }

    // MARK: - Rules

    @Test func aTransferNeedsARunningVMInANormalRunWithNoOtherTransfer() {
        func can(debug: Bool = false, running: Bool = true, socket: Bool = true, busy: Bool = false) -> Bool {
            ColimaModel.canTransferVolumes(isDebug: debug, running: running, hasSocket: socket, transferring: busy)
        }
        #expect(can())
        #expect(!can(debug: true))
        #expect(!can(running: false))
        #expect(!can(socket: false))
        #expect(!can(busy: true))
    }

    @Test func aDebugRunStartsNoTransfer() {
        let model = ColimaModel(profile: "volume-test-profile", readOnly: true)
        #expect(!model.canTransferVolumes)
        let told = Told()
        #expect(!model.mayStartTransfer(tell: told.add))
        #expect(told.texts == [Help.transferDebug])
        #expect(model.volumeTransfer == nil && model.volumeRunner == nil)
    }

    @Test func aStartThatCannotRunTellsTheUserWhy() {
        let model = ColimaModel(profile: "volume-test-profile")
        let told = Told()
        #expect(!model.mayStartTransfer(tell: told.add))
        #expect(told.texts == [Help.transferNeedsVM])
        model.setVolumeTransfer(VolumeTransfer(kind: .backup, volume: "data"))
        #expect(!model.mayStartTransfer(tell: told.add))
        #expect(told.texts == [Help.transferNeedsVM, Help.transferBusy])
    }

    @Test func aCancelMarksTheTransferAsStopping() {
        let model = ColimaModel(profile: "volume-test-profile", readOnly: true)
        model.setVolumeTransfer(VolumeTransfer(kind: .backup, volume: "data"))
        model.cancelVolumeTransfer()
        #expect(model.volumeTransfer?.isCancelling == true)
    }

    @Test func aVMTypeChangeBlocksManualTransfersButNotItsOwn() {
        #expect(
            !ColimaModel.canTransferVolumes(
                isDebug: false, running: true, hasSocket: true, transferring: false, recreating: true))
        let model = ColimaModel(profile: "volume-test-profile", readOnly: true)
        model.setRecreate(VMRecreateProgress(profile: "volume-test-profile", step: .preparing))
        #expect(model.transferBlockReason(fromRecreate: false) == Help.transferDebug)
        let live = ColimaModel(profile: "volume-test-profile")
        live.setRecreate(VMRecreateProgress(profile: "volume-test-profile", step: .preparing))
        #expect(live.transferBlockReason(fromRecreate: false) == Help.recreateBusy)
        // Its own transfers fail only for the VM state: this model has no running VM.
        #expect(live.transferBlockReason(fromRecreate: true) == Help.transferNeedsVM)
    }

    @Test func aTransferThatCannotStartReturnsNilAndPostsNothingWhenItDoesNotNotify() async {
        let model = ColimaModel(profile: "volume-test-profile", readOnly: true)
        let rows = [VolumeRow(name: "data", size: 1, links: 0, project: nil, isAnonymous: false)]
        let folder = URL(fileURLWithPath: "/nonexistent/a.tar")
        let summary = await model.performBackup(
            volumes: rows, destinations: [folder], replace: false, folder: nil, notifies: false, fromRecreate: true)
        #expect(summary == nil)
        let restored = await model.performRestore(
            file: folder, scan: .init(size: 0, skip: 0, meta: nil, entryCount: 0), target: "data", isNew: true,
            confirmReplace: { _ in false }, notifies: false, fromRecreate: true)
        #expect(restored == nil)
        #expect(model.volumeTransfer == nil && model.volumeRunner == nil)
    }

    // MARK: - Helper containers

    @Test func theDashboardHidesHelperContainers() throws {
        let list = try containers(
            """
            [{"Id":"1","Names":["/web"],"Image":"x","State":"running","Status":"Up"},
             {"Id":"2","Names":["/colimabar-helper-1"],"Image":"x","State":"created","Status":"Created",
              "Labels":{"com.imohitkr.colimabar.helper":"1","com.imohitkr.colimabar.helper.kind":"volume"}}]
            """)
        #expect(ColimaModel.visibleContainers(list).map(\.Id) == ["1"])
    }

    @Test func aHelperContainerGetsNoCrashAlertAndNoSavedLog() {
        let helper = ["com.imohitkr.colimabar.helper": "1", "name": "colimabar-helper-1"]
        #expect(ColimaModel.isInternalContainer(name: "colimabar-helper-1", attributes: helper))
    }

    @Test func aNormalContainerIsNotInternal() {
        #expect(!ColimaModel.isInternalContainer(name: "web", attributes: ["name": "web"]))
    }

    // MARK: - Control

    private func transferModel(_ d: FakeDaemon, debug: Bool = false) -> ColimaModel {
        ColimaModel(profile: "volume-test-profile", readOnly: debug, dockerAPI: DockerAPI(socketPath: d.path))
    }

    private func idle(_ d: FakeDaemon) -> VolumeBackupRunner {
        VolumeBackupRunner(api: DockerAPI(socketPath: d.path), newSuffix: { "cafe0001" })
    }

    @Test func aVMStopCancelsTheTransferAndSaysWhy() throws {
        let d = FakeDaemon(path: TestSocketPath.unique())
        let model = transferModel(d)
        let runner = idle(d)
        model.volumeRunner = runner
        model.volumeProfile = "volume-test-profile"
        model.setVolumeTransfer(VolumeTransfer(kind: .backup, volume: "data"))
        model.stopVolumeTransferForVMChange(.vmStopped)
        #expect(runner.isCancelled)
        #expect(model.volumeTransfer?.isCancelling == true)
        #expect(model.volumeStop == .vmStopped)
    }

    @Test func aStopWithNoTransferChangesNothing() {
        let d = FakeDaemon(path: TestSocketPath.unique())
        let model = transferModel(d)
        model.helperSwept = ["volume-test-profile"]
        model.stopVolumeTransferForVMChange(.profileChanged)
        #expect(model.volumeStop == nil && model.helperSwept == ["volume-test-profile"])
    }

    @Test func aStoppedTransferLetsTheSweepOfItsProfileRunAgain() {
        let d = FakeDaemon(path: TestSocketPath.unique())
        let model = transferModel(d)
        model.helperSwept = ["volume-test-profile", "other"]
        model.volumeProfile = "volume-test-profile"
        model.volumeRunner = idle(d)
        model.setVolumeTransfer(VolumeTransfer(kind: .restore, volume: "data"))
        model.stopVolumeTransferForVMChange(.vmStopped)
        #expect(model.helperSwept == ["other"])
    }

    @Test func aTransferThatLeftAHelperContainerLetsTheSweepRunAgain() async throws {
        let id = String(repeating: "ab", count: 32)
        let d = FakeDaemon(path: TestSocketPath.unique()) { req in
            if req.line.hasPrefix("POST /containers/create") {
                return .init(status: 201, body: Data(#"{"Id":"\#(id)"}"#.utf8))
            }
            if req.line.hasPrefix("GET /containers/\(id)/archive") {
                return .init(chunks: [TarFixture.directory("v/") + TarFixture.endMarker])
            }
            if req.line.hasPrefix("DELETE /containers/") { return .init(status: 500) }
            return .init(status: 404)
        }
        try d.start()
        defer { d.stop() }
        let model = transferModel(d)
        let runner = idle(d)
        _ = await runner.isEmpty(volume: "data")
        model.helperSwept = ["volume-test-profile"]
        model.volumeRunner = runner
        await model.finishTransfer(runner, profile: "volume-test-profile")
        #expect(model.helperSwept.isEmpty && model.volumeRunner == nil && model.volumeTransfer == nil)
    }

    @Test func aTransferThatLeftNoHelperContainerKeepsTheSweepDone() async throws {
        let d = FakeDaemon(path: TestSocketPath.unique())
        try d.start()
        defer { d.stop() }
        let model = transferModel(d)
        model.helperSwept = ["volume-test-profile"]
        await model.finishTransfer(idle(d), profile: "volume-test-profile")
        #expect(model.helperSwept == ["volume-test-profile"])
    }

    @Test func theSweepRunsOncePerProfile() async throws {
        let d = FakeDaemon(path: TestSocketPath.unique())
        try d.start()
        defer { d.stop() }
        let model = transferModel(d)
        let first = try #require(model.sweepHelperLeftoversOnce())
        await first.value
        #expect(model.sweepHelperLeftoversOnce() == nil)
        #expect(d.seen.filter { $0.hasPrefix("GET /containers/json") }.count == 1)
        model.helperSwept.remove("volume-test-profile")
        let again = try #require(model.sweepHelperLeftoversOnce())
        await again.value
        #expect(d.seen.filter { $0.hasPrefix("GET /containers/json") }.count == 2)
    }

    @Test func theSweepNeverRunsInADebugRun() {
        let d = FakeDaemon(path: TestSocketPath.unique())
        let model = transferModel(d, debug: true)
        #expect(model.sweepHelperLeftoversOnce() == nil)
        #expect(model.helperSwept.isEmpty && d.seen.isEmpty)
    }

    @Test func theSweepWaitsWhileATransferRuns() {
        let d = FakeDaemon(path: TestSocketPath.unique())
        let model = transferModel(d)
        model.setVolumeTransfer(VolumeTransfer(kind: .backup, volume: "data"))
        #expect(model.sweepHelperLeftoversOnce() == nil)
        #expect(model.helperSwept.isEmpty)
    }

    @Test func aTransferThatCannotStartTellsTheReason() {
        let d = FakeDaemon(path: TestSocketPath.unique())
        #expect(transferModel(d, debug: true).transferBlockReason == Help.transferDebug)
        let busy = transferModel(d)
        #expect(busy.transferBlockReason == Help.transferNeedsVM)
        busy.setVolumeTransfer(VolumeTransfer(kind: .backup, volume: "data"))
        #expect(busy.transferBlockReason == Help.transferBusy)
    }

    // MARK: - Texts

    @Test func aGoodBackupNamesTheFileAndTheSize() {
        #expect(
            ColimaModel.backupMessage(volume: "pg", file: "pg-20260101-000000.tar", bytes: 120 << 20)
                == "Backed up volume pg to pg-20260101-000000.tar (120 MB).")
    }

    @Test func aFailedBackupSaysThatTheIncompleteFileIsGone() {
        #expect(
            ColimaModel.backupMessage(failure: "Docker did not answer", volume: "pg", removedFile: true)
                == "Backup of pg failed: Docker did not answer. ColimaBar removed the incomplete file.")
    }

    @Test func aBackupThatWroteNoFileDoesNotSayItRemovedOne() {
        let text = ColimaModel.backupMessage(failure: "A file with this name exists.", volume: "pg", removedFile: false)
        #expect(text == "Backup of pg failed: A file with this name exists.")
    }

    @Test func aStoppedBackupSaysThatTheIncompleteFileIsGoneOnlyIfThereWasOne() {
        #expect(
            ColimaModel.backupMessage(cancelled: "pg", removedFile: true)
                == "Backup of pg stopped. ColimaBar removed the incomplete file.")
        #expect(ColimaModel.backupMessage(cancelled: "pg", removedFile: false) == "Backup of pg stopped.")
    }

    @Test func aBackupThatStoppedWithTheVMSaysWhy() {
        #expect(
            ColimaModel.backupMessage(cancelled: "pg", removedFile: true, because: "the VM stopped")
                == "Backup of pg stopped because the VM stopped. ColimaBar removed the incomplete file.")
        #expect(
            ColimaModel.backupAllMessage(
                done: 1, total: 3, folder: "B", failed: [], cancelled: true, because: "you chose another profile")
                == "Backup stopped because you chose another profile after 1 of 3 volumes.")
    }

    @Test func backUpAllGivesOneSummary() {
        func text(
            done: Int, total: Int, failed: [(name: String, reason: String)] = [], cancelled: Bool = false,
            removedFile: Bool = false, diskFull: Bool = false
        ) -> String {
            ColimaModel.backupAllMessage(
                done: done, total: total, folder: "Backups", failed: failed, cancelled: cancelled,
                removedFile: removedFile, diskFull: diskFull)
        }
        #expect(text(done: 3, total: 3) == "Backed up 3 volumes to Backups.")
        #expect(text(done: 1, total: 1) == "Backed up 1 volume to Backups.")
        #expect(
            text(done: 2, total: 3, failed: [("c", "A file with this name exists.")])
                == "Backed up 2 of 3 volumes to Backups. Failed: c (A file with this name exists).")
        #expect(
            text(done: 1, total: 3, cancelled: true, removedFile: true)
                == "Backup stopped after 1 of 3 volumes. ColimaBar removed the incomplete file.")
        #expect(text(done: 1, total: 3, cancelled: true) == "Backup stopped after 1 of 3 volumes.")
        #expect(
            text(done: 1, total: 3, failed: [("b", "The disk of your Mac is full.")], diskFull: true)
                == "Backed up 1 of 3 volumes to Backups. Failed: b (The disk of your Mac is full). ColimaBar stopped, because the disk of your Mac is full."
        )
    }

    // MARK: - Backup summaries

    private func summary(
        done: [VolumeBackupBatch.Done] = [], failed: [VolumeBackupBatch.Failed] = [], started: Bool = true,
        cancelled: Bool = false, prepare: String? = nil
    ) -> VolumeBackupBatch.Summary {
        var s = VolumeBackupBatch.Summary()
        s.done = done
        s.failed = failed
        s.started = started
        s.cancelled = cancelled
        s.prepareFailure = prepare
        return s
    }

    @Test func aCancelBeforeTheFirstVolumeGivesNoNotification() {
        let s = summary(started: false, cancelled: true)
        #expect(ColimaModel.backupMessage(summary: s, volumes: ["pg"], folder: nil, because: nil) == nil)
        #expect(ColimaModel.backupMessage(summary: s, volumes: ["a", "b"], folder: "F", because: nil) == nil)
    }

    @Test func aStopBecauseOfTheVMGivesANotificationEvenBeforeTheFirstVolume() {
        let s = summary(started: false, cancelled: true)
        #expect(
            ColimaModel.backupMessage(summary: s, volumes: ["pg"], folder: nil, because: "the VM stopped")
                == "Backup of pg stopped because the VM stopped.")
    }

    @Test func aFailedImageLoadNamesTheReasonAndNoFile() {
        let s = summary(started: false, prepare: "Docker did not answer.")
        #expect(
            ColimaModel.backupMessage(summary: s, volumes: ["pg"], folder: nil, because: nil)
                == "Backup of pg failed: Docker did not answer.")
        #expect(
            ColimaModel.backupMessage(summary: s, volumes: ["a", "b"], folder: "F", because: nil)
                == "Backup of the volumes failed: Docker did not answer.")
    }

    @Test func aSingleBackupGetsItsOwnNotification() {
        let done = summary(done: [.init(name: "pg", file: "pg.tar", bytes: 1 << 20)])
        #expect(
            ColimaModel.backupMessage(summary: done, volumes: ["pg"], folder: nil, because: nil)
                == "Backed up volume pg to pg.tar (1.0 MB).")
        let failed = summary(failed: [
            .init(name: "pg", reason: "The volume does not exist any more.", removedFile: false)
        ])
        #expect(
            ColimaModel.backupMessage(summary: failed, volumes: ["pg"], folder: nil, because: nil)
                == "Backup of pg failed: The volume does not exist any more.")
    }

    @Test func aBackupOfManyVolumesGetsOneNotification() {
        let s = summary(
            done: [.init(name: "a", file: "a.tar", bytes: 1)],
            failed: [.init(name: "b", reason: "A file with this name exists.", removedFile: false)])
        #expect(
            ColimaModel.backupMessage(summary: s, volumes: ["a", "b"], folder: "Backups", because: nil)
                == "Backed up 1 of 2 volumes to Backups. Failed: b (A file with this name exists).")
    }

    // MARK: - Restore texts

    @Test func aStoppedRestoreSaysWhatChanged() {
        func text(_ change: VolumeRestoreFlow.Change) -> String {
            ColimaModel.restoreMessage(cancelledFile: "pg.tar", change: change, volume: "pg")
        }
        #expect(text(.nothing) == "Restore of pg.tar stopped. Nothing changed.")
        #expect(text(.newVolumeRemoved) == "Restore of pg.tar stopped. ColimaBar removed the new volume pg.")
        #expect(text(.partial) == "Restore of pg.tar stopped. The volume pg can hold part of the files.")
    }

    @Test func aRestoreThatStoppedWithTheVMSaysWhy() {
        #expect(
            ColimaModel.restoreMessage(
                cancelledFile: "pg.tar", change: .nothing, volume: "pg", because: "the VM stopped")
                == "Restore of pg.tar stopped because the VM stopped. Nothing changed.")
    }

    @Test func theTextAfterAReplaceThatLostFilesNamesTheFileToRestoreAgain() {
        #expect(
            ColimaModel.restoreMessage(
                file: "pg.tar", volume: "pg", deletedOld: true, state: .partial, reason: "HTTP 500")
                == "Restore failed: HTTP 500. The old files of volume pg are deleted. The volume holds part of the backup. Restore again from pg.tar."
        )
        #expect(
            ColimaModel.restoreMessage(file: "pg.tar", volume: "pg", deletedOld: true, state: .gone, reason: nil)
                == "Restore of pg.tar stopped. The old files of volume pg are deleted. The volume does not exist now. Restore again from pg.tar."
        )
    }

    @Test func theTextForANewVolumeThatStaysNamesTheVolume() {
        #expect(
            ColimaModel.restoreMessage(file: "pg.tar", stoppedBecause: "HTTP 500", keptNewVolume: "pg2")
                == "Restore failed: HTTP 500. ColimaBar could not remove the new volume pg2. Remove it in the Volumes tab."
        )
    }

    @Test func theTextForAnOptionVolumeOffersARestoreToANewVolume() {
        #expect(
            ColimaModel.restoreMessage(driverOptionsOf: "nfs1")
                == "Volume nfs1 uses driver options (for example a bind folder or NFS). ColimaBar cannot replace its files. Restore to a new volume instead."
        )
    }

    @Test func theTextForANameThatAVolumeTookMeanwhileOffersAnotherName() {
        #expect(
            ColimaModel.restoreMessage(volumeExistsNow: "pg")
                == "A volume named pg exists now. Restore again and choose another name.")
    }

    @Test func aRestoreNamesTheFileAndTheVolumeButNoPath() {
        #expect(ColimaModel.restoreMessage(file: "pg.tar", volume: "pgdata") == "Restored pg.tar to volume pgdata.")
    }

    @Test func aRefusedRestoreNamesTheContainers() {
        #expect(
            ColimaModel.restoreMessage(volume: "pg", users: ["db", "web"])
                == "Containers use volume pg: db, web. Remove them first, or restore to a new volume.")
    }

    @Test func aBadFileGivesAClearReason() {
        #expect(
            ColimaModel.restoreMessage(scan: .notComplete) == "Restore failed: The file is not a complete tar archive.")
        #expect(
            ColimaModel.restoreMessage(scan: .unsafeEntry("v/../x"))
                == "Restore failed: The file has an unsafe entry: v/../x.")
        #expect(
            ColimaModel.restoreMessage(scan: .compressed)
                == "Restore failed: The file is compressed. Run gunzip on it first.")
        #expect(ColimaModel.restoreMessage(scan: .unreadable) == "Restore failed: ColimaBar cannot read the file.")
    }

    @Test func aSentenceGetsAFullStopOnce() {
        #expect(ColimaModel.sentence("No space") == "No space.")
        #expect(ColimaModel.sentence("No space. ") == "No space.")
    }

    @Test func noMessageHasAFullPath() {
        let texts = [
            ColimaModel.backupMessage(volume: "pg", file: "pg.tar", bytes: 1),
            ColimaModel.restoreMessage(file: "pg.tar", volume: "pg"),
            ColimaModel.backupAllMessage(done: 2, total: 2, folder: "Backups", failed: [], cancelled: false),
        ]
        #expect(texts.allSatisfy { !$0.contains("/") })
    }
}

/// The texts that a model told, in order.
private final class Told {
    private(set) var texts: [String] = []
    func add(_ text: String) { texts.append(text) }
}
