import Foundation

/// The order of the steps of a VM type change: back up the volumes, save the
/// images, recreate the VM, wait for Docker, then restore what is missing.
/// The steps are closures, so a test can run the flow with fakes.
/// `ColimaModel+VMRecreate` gives it the real ones.
///
/// Before the recreate, a failure or a cancel stops the flow and the VM stays
/// as it is. After it, a failure keeps the journal, so the user can restore
/// the backups later. The restore is idempotent: it restores only the volumes
/// and images that are missing, so a data disk that Colima kept makes it a
/// no-op.
enum VMRecreateFlow {
    struct Steps {
        var backUp: @MainActor ([VolumeRow], URL) async -> VolumeBackupBatch.Summary?
        var saveImages:
            @MainActor ([String], URL) async -> Result<(bytes: Int64, sha256: String), VolumeBackupRunner.Failure>
        var recreate: @MainActor (_ vmType: String, _ mountType: String) async -> Shell.Result
        var waitReady: @MainActor () async -> Bool
        var readTypes: @MainActor () -> (vmType: String, mountType: String)?
        /// Why the flow must stop before a restore step, or nil if it may go on.
        var stopReason: @MainActor () -> VolumeTransferStop?
        /// Restores one volume from its file in the folder. Nil if it could not start.
        var restore: @MainActor (VMRecreateJournal.Volume, URL) async -> VolumeRestoreFlow.Outcome?
        /// True if the volume exists now. Nil if Docker does not answer.
        var volumeExists: @MainActor (String) async -> Bool?
        /// The saved references that Docker does not have now. Nil if Docker does not answer.
        var missingImages: @MainActor ([String]) async -> [String]?
        var loadImages: @MainActor (_ file: URL, _ sha256: String) async -> VolumeBackupRunner.Failure?
        var saveJournal: @MainActor (VMRecreateJournal) -> Void
        var dropJournal: @MainActor () -> Void
        var progress: @MainActor (VMRecreateProgress.Step) -> Void
    }

    enum Outcome: Equatable {
        case finished(restored: Int, kept: Int, failed: [String], imagesLoaded: Bool)
        /// The VM did not change. The text says why.
        case nothingChanged(String)
        /// The user cancelled before the VM changed.
        case cancelledBeforeChange
        /// The VM changed, and the journal stays. The text says what to do.
        case restorePending(String)
        /// The new VM did not start, and nothing was backed up. The journal is gone.
        case changedWithoutBackup(String)
    }

    /// The whole flow. `journal` has phase `backup`. `folder` is the backup
    /// folder, or nil if nothing is backed up. `restop` is true for a VM that
    /// was stopped: the script stops it again, and there is nothing to restore.
    @MainActor
    static func run(
        _ journal: VMRecreateJournal, folder: URL?, backUp: [VolumeRow], saveImages: [String], restop: Bool,
        steps: Steps
    ) async -> Outcome {
        var j = journal
        let named = folder?.lastPathComponent ?? ""
        if folder != nil { steps.saveJournal(j) }
        /// The files that the backup wrote so far stay in the folder.
        func soFar(_ text: String) -> String {
            named.isEmpty || (j.volumes.isEmpty && j.imagesFile == nil) ? "" : " \(text) \(named)."
        }
        func stopBefore(_ reason: String) -> Outcome {
            steps.dropJournal()
            return .nothingChanged(
                "Backup failed, so nothing changed: \(ColimaModel.sentence(reason))"
                    + soFar("The backups so far are in"))
        }
        if let folder, !backUp.isEmpty {
            steps.progress(.backingUp)
            guard let summary = await steps.backUp(backUp, folder) else {
                steps.dropJournal()
                return .nothingChanged("ColimaBar could not start the backup.")
            }
            j.volumes = summary.done.map { .init(name: $0.name, file: $0.file) }
            if summary.cancelled {
                steps.dropJournal()
                return .cancelledBeforeChange
            }
            if let reason = summary.prepareFailure ?? summary.failed.first.map({ "\($0.name): \($0.reason)" })
                ?? (summary.diskFull ? VolumeBackupRunner.Failure.diskFull.reason : nil)
            {
                return stopBefore(reason)
            }
        }
        if let folder, !saveImages.isEmpty {
            steps.progress(.savingImages)
            switch await steps.saveImages(saveImages, folder) {
            case .success(let saved):
                j.imagesFile = "images.tar"
                j.imagesSHA256 = saved.sha256
                j.images = saveImages
            case .failure(let f) where f.cancelled:
                steps.dropJournal()
                return .cancelledBeforeChange
            case .failure(let f):
                return stopBefore(f.reason)
            }
        }
        j.phase = .recreate
        steps.saveJournal(j)
        steps.progress(.recreating)
        let result = await steps.recreate(j.to.vmType, j.to.mountType)
        let hasBackup = !j.volumes.isEmpty || j.imagesFile != nil
        if result.status == 2 {
            steps.dropJournal()
            return .nothingChanged("Nothing changed." + soFar("The backups are in"))
        }
        guard result.ok else {
            let now = steps.readTypes()
            if let now, now != (j.to.vmType, j.to.mountType) {
                // colima.yaml has other values: the script changed nothing, or restored the old file.
                steps.dropJournal()
                return .nothingChanged("Nothing changed." + soFar("The backups are in"))
            }
            guard hasBackup else {
                steps.dropJournal()
                return .changedWithoutBackup(
                    "The VM of profile \(j.profile) did not start with \(j.to.vmType) / \(j.to.mountType).")
            }
            if now != nil {
                j.phase = .restore
                steps.saveJournal(j)
            }
            return .restorePending(
                "The VM of profile \(j.profile) did not start with \(j.to.vmType) / \(j.to.mountType). The backups are in \(named). Start the VM, then click Restore Backups."
            )
        }
        if restop {
            steps.dropJournal()
            return .finished(restored: 0, kept: 0, failed: [], imagesLoaded: false)
        }
        j.phase = .restore
        steps.saveJournal(j)
        guard hasBackup, let folder else {
            steps.dropJournal()
            return .finished(restored: 0, kept: 0, failed: [], imagesLoaded: false)
        }
        steps.progress(.waiting)
        guard await steps.waitReady() else {
            return .restorePending(
                "Docker did not get ready. The backups are in \(named). Click Restore Backups when the VM runs.")
        }
        return await restoreMissing(j, folder: folder, steps: steps)
    }

    /// Restores the volumes and images of a journal that are missing now. The
    /// user starts it with **Restore Backups** after a quit or a failure.
    @MainActor
    static func resume(_ journal: VMRecreateJournal, folder: URL, steps: Steps) async -> Outcome {
        var j = journal
        j.phase = .restore
        steps.saveJournal(j)
        return await restoreMissing(j, folder: folder, steps: steps)
    }

    @MainActor
    private static func restoreMissing(_ j: VMRecreateJournal, folder: URL, steps: Steps) async -> Outcome {
        let named = folder.lastPathComponent
        func stopped(_ because: String?) -> Outcome {
            .restorePending(
                "ColimaBar stopped the restore\(because.map { " because \($0)" } ?? ""). The backups are in \(named). Click Restore Backups to go on."
            )
        }
        var restored = 0
        var kept = 0
        var failed: [String] = []
        for volume in j.volumes {
            if let why = steps.stopReason() { return stopped(why.because) }
            steps.progress(.restoring)
            guard let exists = await steps.volumeExists(volume.name) else {
                failed.append("\(volume.name) (Docker did not answer)")
                continue
            }
            if exists {
                kept += 1
                continue
            }
            switch await steps.restore(volume, folder) {
            case .done?: restored += 1
            case .cancelled?: return stopped(steps.stopReason()?.because)
            case .failed(let text)?, .refused(let text)?, .notice(let text)?: failed.append("\(volume.name) (\(text))")
            case .declined?, nil: failed.append("\(volume.name) (ColimaBar could not restore it)")
            }
        }
        var loaded = false
        if let file = j.imagesFile, let sha = j.imagesSHA256, !j.images.isEmpty {
            if let why = steps.stopReason() { return stopped(why.because) }
            if let missing = await steps.missingImages(j.images) {
                if !missing.isEmpty {
                    steps.progress(.loadingImages)
                    if let f = await steps.loadImages(folder.appendingPathComponent(file), sha) {
                        if f.cancelled { return stopped(steps.stopReason()?.because) }
                        failed.append("images (\(f.reason))")
                    } else {
                        loaded = true
                    }
                }
            } else {
                failed.append("images (Docker did not answer)")
            }
        }
        if failed.isEmpty { steps.dropJournal() }
        return .finished(restored: restored, kept: kept, failed: failed, imagesLoaded: loaded)
    }
}
