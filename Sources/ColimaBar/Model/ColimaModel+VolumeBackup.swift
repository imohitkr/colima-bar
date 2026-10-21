import Foundation

/// Volume backup and restore. The work runs through `VolumeBackupRunner` on
/// the socket of the selected profile, so it never starts the VM. One
/// transfer at a time. A debug run starts none.
extension ColimaModel {
    /// The rule for a start: a normal run, a running VM with a docker
    /// socket, and no other transfer.
    /// `recreating` is true while a VM type change runs: only its own
    /// transfers may start then.
    nonisolated static func canTransferVolumes(
        isDebug: Bool, running: Bool, hasSocket: Bool, transferring: Bool, recreating: Bool = false
    ) -> Bool {
        !isDebug && running && hasSocket && !transferring && !recreating
    }

    var canTransferVolumes: Bool {
        Self.canTransferVolumes(
            isDebug: isDebug, running: state == .running, hasSocket: hasDockerSocket,
            transferring: volumeTransfer != nil, recreating: recreate != nil)
    }

    // MARK: - Reads for the panels

    /// The names of the running containers that use the volume, for the
    /// warning before a backup. Nil if the daemon does not answer.
    func runningUsers(of volume: String) async -> [String]? {
        guard hasDockerSocket, state == .running, !isDebug else { return nil }
        return await VolumeBackupRunner(api: api).users(of: volume, runningOnly: true)
    }

    /// True if no volume has this name now (the list of the dashboard).
    func isVolumeNameTaken(_ name: String) -> Bool { volumes.contains { $0.name == name } }

    /// Checks a backup file before a restore. A problem goes to a
    /// notification and gives nil.
    func scanBackup(file: URL) async -> TarFileScan.Summary? {
        let path = file.path
        let result: Result<TarFileScan.Summary, TarFileScan.Failure> = await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                do { cont.resume(returning: .success(try TarFileScan.scan(path: path))) } catch {
                    cont.resume(returning: .failure(error as? TarFileScan.Failure ?? .unreadable))
                }
            }
        }
        switch result {
        case .success(let summary): return summary
        case .failure(let failure):
            notify(Self.restoreMessage(scan: failure))
            return nil
        }
    }

    // MARK: - Backup

    /// Backs up one volume to `url`. The save panel confirmed a replace.
    func backUp(volume: VolumeRow, to url: URL) {
        backUp(volumes: [volume], destinations: [url], replace: true, folder: nil)
    }

    /// Backs up each volume to its own file in `folder`. A file that exists
    /// is never replaced.
    func backUpAll(volumes rows: [VolumeRow], into folder: URL) {
        let names = VolumeBackupName.fileNames(
            for: rows.map { ($0.name, $0.isAnonymous) }, date: Date())
        backUp(
            volumes: rows, destinations: names.map { folder.appendingPathComponent($0) }, replace: false,
            folder: folder.lastPathComponent)
    }

    private func backUp(volumes rows: [VolumeRow], destinations: [URL], replace: Bool, folder: String?) {
        // The transfer starts now, not in the Task, so a second click can't race it.
        guard let job = beginBackup(rows, destinations: destinations, notifies: true, fromRecreate: false) else {
            return
        }
        Task { _ = await runBackup(job, replace: replace, folder: folder, notifies: true) }
    }

    /// Backs up the volumes in order and returns the summary. It returns nil
    /// if no transfer may start (see `mayStartTransfer`). With `notifies`, it
    /// posts the result. The VM type change runs it with `fromRecreate` and
    /// no notification.
    func performBackup(
        volumes rows: [VolumeRow], destinations: [URL], replace: Bool, folder: String?, notifies: Bool,
        fromRecreate: Bool = false
    ) async -> VolumeBackupBatch.Summary? {
        guard let job = beginBackup(rows, destinations: destinations, notifies: notifies, fromRecreate: fromRecreate)
        else { return nil }
        return await runBackup(job, replace: replace, folder: folder, notifies: notifies)
    }

    private struct BackupJob {
        let runner: VolumeBackupRunner
        let profile: String
        let items: [VolumeBackupBatch.Item]
    }

    private func beginBackup(
        _ rows: [VolumeRow], destinations: [URL], notifies: Bool, fromRecreate: Bool
    ) -> BackupJob? {
        guard !rows.isEmpty, mayStartTransfer(fromRecreate: fromRecreate, tell: notifies ? nil : { _ in }) else {
            return nil
        }
        let runner = VolumeBackupRunner(api: api)
        // A Cancel of a VM type change that came before this step must stop it at once.
        if fromRecreate, recreate?.isCancelling == true { runner.cancel() }
        volumeRunner = runner
        volumeProfile = profile
        setVolumeTransfer(VolumeTransfer(kind: .backup, volume: rows[0].name, total: rows[0].size))
        let items = zip(rows, destinations).map {
            VolumeBackupBatch.Item(name: $0.name, size: $0.size, destination: $1.path)
        }
        return BackupJob(runner: runner, profile: profile, items: items)
    }

    private func runBackup(_ job: BackupJob, replace: Bool, folder: String?, notifies: Bool) async
        -> VolumeBackupBatch.Summary
    {
        let count = job.items.count
        let summary = await VolumeBackupBatch.run(
            runner: job.runner, items: job.items, replace: replace, app: "ColimaBar \(AppDelegate.version)",
            willStart: { [self] i, item in
                setVolumeTransfer(
                    VolumeTransfer(
                        kind: .backup, volume: item.name, total: item.size, position: count > 1 ? i + 1 : nil,
                        count: count))
            },
            onProgress: { [weak self] bytes in Task { @MainActor in self?.transferProgress(bytes) } })
        if notifies,
            let text = Self.backupMessage(
                summary: summary, volumes: job.items.map(\.name), folder: folder, because: volumeStop?.because)
        {
            notify(text)
        }
        await finishTransfer(job.runner, profile: job.profile)
        return summary
    }

    // MARK: - Restore

    /// Restores a backup into the volume `name` that exists. A volume with
    /// files needs `confirmReplace` to say yes. Containers that use it stop
    /// the restore.
    func restore(
        file: URL, scan: TarFileScan.Summary, into name: String, confirmReplace: @escaping @MainActor (String) -> Bool
    ) {
        startRestore(file: file, scan: scan, target: name, isNew: false, confirmReplace: confirmReplace)
    }

    /// Restores a backup into a new volume. `name` must pass
    /// `VolumeBackupName.isValidNewName`.
    func restoreToNew(file: URL, scan: TarFileScan.Summary, name: String) {
        guard VolumeBackupName.isValidNewName(name) else { return }
        startRestore(file: file, scan: scan, target: name, isNew: true, confirmReplace: { _ in false })
    }

    private func startRestore(
        file: URL, scan: TarFileScan.Summary, target: String, isNew: Bool,
        confirmReplace: @escaping @MainActor (String) -> Bool
    ) {
        guard let job = beginRestore(target, notifies: true, fromRecreate: false) else { return }
        Task {
            _ = await runRestore(
                job, file: file, scan: scan, isNew: isNew, confirmReplace: confirmReplace, notifies: true)
        }
    }

    /// Restores a backup file into the volume `target` and returns what
    /// happened. It returns nil if no transfer may start. With `notifies`, it
    /// posts the result. The VM type change runs it with `fromRecreate`.
    func performRestore(
        file: URL, scan: TarFileScan.Summary, target: String, isNew: Bool,
        confirmReplace: @escaping @MainActor (String) -> Bool, notifies: Bool, fromRecreate: Bool = false
    ) async -> VolumeRestoreFlow.Outcome? {
        guard let job = beginRestore(target, notifies: notifies, fromRecreate: fromRecreate) else { return nil }
        return await runRestore(
            job, file: file, scan: scan, isNew: isNew, confirmReplace: confirmReplace, notifies: notifies)
    }

    private struct RestoreJob {
        let runner: VolumeBackupRunner
        let profile: String
        let target: String
    }

    private func beginRestore(_ target: String, notifies: Bool, fromRecreate: Bool) -> RestoreJob? {
        guard mayStartTransfer(fromRecreate: fromRecreate, tell: notifies ? nil : { _ in }) else { return nil }
        let runner = VolumeBackupRunner(api: api)
        // A Cancel of a VM type change that came before this step must stop it at once.
        if fromRecreate, recreate?.isCancelling == true { runner.cancel() }
        volumeRunner = runner
        volumeProfile = profile
        var checking = VolumeTransfer(kind: .restore, volume: target)
        checking.isChecking = true
        setVolumeTransfer(checking)
        return RestoreJob(runner: runner, profile: profile, target: target)
    }

    private func runRestore(
        _ job: RestoreJob, file: URL, scan: TarFileScan.Summary, isNew: Bool,
        confirmReplace: @escaping @MainActor (String) -> Bool, notifies: Bool
    ) async -> VolumeRestoreFlow.Outcome {
        let target = job.target
        let fileName = file.lastPathComponent
        let outcome = await VolumeRestoreFlow.run(
            runner: job.runner, file: file.path, scan: scan, target: target, isNew: isNew,
            confirmReplace: confirmReplace,
            willSend: { [self] in
                setVolumeTransfer(
                    VolumeTransfer(kind: .restore, volume: target, total: Double(scan.size - scan.skip)))
            },
            onProgress: { [weak self] bytes in Task { @MainActor in self?.transferProgress(bytes) } })
        if notifies {
            switch outcome {
            case .done: notify(Self.restoreMessage(file: fileName, volume: target))
            case .declined: break
            case .cancelled(let change):
                notify(
                    Self.restoreMessage(
                        cancelledFile: fileName, change: change, volume: target, because: volumeStop?.because))
            case .refused(let text), .notice(let text): notify(text)
            case .failed(let reason): notify(Self.restoreMessage(failure: reason))
            }
        }
        await finishTransfer(job.runner, profile: job.profile)
        return outcome
    }

    // MARK: - Control

    /// Why a transfer cannot start now, or nil. A hint and a notification use it.
    var transferBlockReason: String? { transferBlockReason(fromRecreate: false) }

    /// `fromRecreate` is true for the transfers of a VM type change: the
    /// change itself does not block them.
    func transferBlockReason(fromRecreate: Bool) -> String? {
        let can = Self.canTransferVolumes(
            isDebug: isDebug, running: state == .running, hasSocket: hasDockerSocket,
            transferring: volumeTransfer != nil, recreating: recreate != nil && !fromRecreate)
        if can { return nil }
        if isDebug { return Help.transferDebug }
        if volumeTransfer != nil { return Help.transferBusy }
        if recreate != nil, !fromRecreate { return Help.recreateBusy }
        return Help.transferNeedsVM
    }

    /// True if a transfer can start. If not, it tells the user why: with a
    /// notification, or with `tell` (for tests).
    func mayStartTransfer(fromRecreate: Bool = false, tell: ((String) -> Void)? = nil) -> Bool {
        guard let reason = transferBlockReason(fromRecreate: fromRecreate) else { return true }
        if let tell { tell(reason) } else { notify(reason) }
        return false
    }

    /// Stops the transfer that runs now. The runner removes its helper
    /// container and the incomplete file.
    func cancelVolumeTransfer() {
        guard var t = volumeTransfer, !t.isCancelling else { return }
        t.isCancelling = true
        setVolumeTransfer(t)
        volumeRunner?.cancel()
    }

    /// The VM stopped or the profile changed: the transfer cannot go on. The
    /// notification says why. The helper container can stay in the VM, so the
    /// sweep of its profile runs again.
    func stopVolumeTransferForVMChange(_ why: VolumeTransferStop) {
        guard var t = volumeTransfer else { return }
        volumeStop = why
        t.isCancelling = true
        setVolumeTransfer(t)
        helperSwept.remove(volumeProfile ?? profile)
        volumeRunner?.cancel()
    }

    func finishTransfer(_ runner: VolumeBackupRunner, profile started: String) async {
        await runner.release()
        // A helper container that stays can hold a volume: the next sweep removes it.
        if runner.leftHelperContainer { helperSwept.remove(started) }
        if volumeRunner === runner {
            volumeRunner = nil
            volumeProfile = nil
            volumeStop = nil
            setVolumeTransfer(nil)
        }
    }

    private func transferProgress(_ bytes: Int64) {
        guard var t = volumeTransfer, !t.isChecking, bytes > t.bytes else { return }
        t.bytes = bytes
        setVolumeTransfer(t)
    }

    /// Removes the helper containers that an earlier run left. It runs once
    /// for each profile, after the first good container refresh of a normal
    /// run, and never during a transfer. A transfer that starts later stops it.
    /// Returns the sweep, or nil if none starts.
    @discardableResult
    func sweepHelperLeftoversOnce() -> Task<Void, Never>? {
        guard !isDebug, volumeTransfer == nil, !helperSwept.contains(profile) else { return nil }
        helperSwept.insert(profile)
        let client = api
        return Task {
            await VolumeBackupRunner.sweepLeftovers(
                api: client, isBusy: { @MainActor [weak self] in self?.volumeTransfer != nil })
        }
    }

    /// True for a container that ColimaBar runs for itself: a debug shell or a
    /// volume helper. It gets no crash alert and no saved log.
    nonisolated static func isInternalContainer(name: String?, attributes: [String: String]) -> Bool {
        DebugShell.isSidecar(name: name) || HelperImage.isHelper(labels: attributes)
    }

    /// The containers of the list that the dashboard shows: the helper
    /// containers of a volume backup are left out.
    nonisolated static func visibleContainers(_ list: [APIContainer]) -> [APIContainer] {
        list.filter { !HelperImage.isHelper(labels: $0.Labels) }
    }

    // MARK: - Texts

    nonisolated static func backupMessage(volume: String, file: String, bytes: Int64) -> String {
        "Backed up volume \(volume) to \(file) (\(ByteFormat.bytes(Double(bytes))))."
    }

    nonisolated static func backupMessage(failure reason: String, volume: String, removedFile: Bool) -> String {
        "Backup of \(volume) failed: \(sentence(reason))"
            + (removedFile ? " ColimaBar removed the incomplete file." : "")
    }

    nonisolated static func backupMessage(cancelled volume: String, removedFile: Bool, because: String? = nil) -> String
    {
        "Backup of \(volume) stopped\(because.map { " because \($0)" } ?? "")."
            + (removedFile ? " ColimaBar removed the incomplete file." : "")
    }

    nonisolated static func backupAllMessage(
        done: Int, total: Int, folder: String, failed: [(name: String, reason: String)], cancelled: Bool,
        removedFile: Bool = false, diskFull: Bool = false, because: String? = nil
    ) -> String {
        let noun = { (n: Int) in n == 1 ? "1 volume" : "\(n) volumes" }
        if cancelled {
            return "Backup stopped\(because.map { " because \($0)" } ?? "") after \(done) of \(total) volumes."
                + (removedFile ? " ColimaBar removed the incomplete file." : "")
        }
        if failed.isEmpty { return "Backed up \(noun(done)) to \(folder)." }
        let list = failed.map { "\($0.name) (\(shortReason($0.reason)))" }.joined(separator: ", ")
        let head = "Backed up \(done) of \(total) volumes to \(folder). Failed: \(list)."
        return diskFull ? head + " ColimaBar stopped, because the disk of your Mac is full." : head
    }

    /// The notification for the end of a backup run, or nil if the user
    /// cancelled before anything happened. One volume gets its own text.
    nonisolated static func backupMessage(
        summary s: VolumeBackupBatch.Summary, volumes: [String], folder: String?, because: String?
    ) -> String? {
        if let reason = s.prepareFailure {
            return volumes.count == 1
                ? backupMessage(failure: reason, volume: volumes[0], removedFile: false)
                : "Backup of the volumes failed: \(sentence(reason))"
        }
        // The user stopped it before the first volume: nothing to tell.
        if s.cancelled, !s.started, because == nil { return nil }
        if volumes.count == 1 {
            if let d = s.done.first { return backupMessage(volume: d.name, file: d.file, bytes: d.bytes) }
            if let f = s.failed.first {
                return backupMessage(failure: f.reason, volume: f.name, removedFile: f.removedFile)
            }
            return backupMessage(cancelled: volumes[0], removedFile: s.cancelRemovedFile, because: because)
        }
        return backupAllMessage(
            done: s.done.count, total: volumes.count, folder: folder ?? "",
            failed: s.failed.map { ($0.name, $0.reason) }, cancelled: s.cancelled, removedFile: s.cancelRemovedFile,
            diskFull: s.diskFull, because: because)
    }

    /// A reason without its last full stop, at most 60 characters.
    nonisolated private static func shortReason(_ text: String) -> String {
        var t = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60))
        if t.hasSuffix(".") { t.removeLast() }
        return t
    }

    nonisolated static func restoreMessage(file: String, volume: String) -> String {
        "Restored \(file) to volume \(volume)."
    }

    nonisolated static func restoreMessage(
        cancelledFile file: String, change: VolumeRestoreFlow.Change, volume: String, because: String? = nil
    ) -> String {
        let head = "Restore of \(file) stopped\(because.map { " because \($0)" } ?? "")."
        switch change {
        case .nothing: return head + " Nothing changed."
        case .newVolumeRemoved: return head + " ColimaBar removed the new volume \(volume)."
        case .partial: return head + " The volume \(volume) can hold part of the files."
        }
    }

    /// The old files are gone. `state` says what the volume holds now.
    enum DeletedVolumeState { case gone, partial }

    nonisolated static func restoreMessage(
        file: String, volume: String, deletedOld: Bool, state: DeletedVolumeState, reason: String?
    ) -> String {
        let head = reason.map { "Restore failed: \(sentence($0))" } ?? "Restore of \(file) stopped."
        let now =
            state == .gone
            ? "The volume does not exist now."
            : "The volume holds part of the backup."
        return "\(head) The old files of volume \(volume) are deleted. \(now) Restore again from \(file)."
    }

    /// A stop where the new volume stays. `reason` is nil for a cancel.
    nonisolated static func restoreMessage(file: String, stoppedBecause reason: String?, keptNewVolume volume: String)
        -> String
    {
        let head = reason.map { "Restore failed: \(sentence($0))" } ?? "Restore of \(file) stopped."
        return "\(head) ColimaBar could not remove the new volume \(volume). Remove it in the Volumes tab."
    }

    nonisolated static func restoreMessage(volumeExistsNow volume: String) -> String {
        "A volume named \(volume) exists now. Restore again and choose another name."
    }

    nonisolated static func restoreMessage(driverOptionsOf volume: String) -> String {
        "Volume \(volume) uses driver options (for example a bind folder or NFS). ColimaBar cannot replace its files. Restore to a new volume instead."
    }

    nonisolated static func restoreMessage(failure reason: String) -> String {
        "Restore failed: \(sentence(reason))"
    }

    nonisolated static func restoreMessage(volume: String, users: [String]) -> String {
        "Containers use volume \(volume): \(users.joined(separator: ", ")). Remove them first, or restore to a new volume."
    }

    nonisolated static func restoreMessage(scan failure: TarFileScan.Failure) -> String {
        switch failure {
        case .unreadable: restoreMessage(failure: "ColimaBar cannot read the file.")
        case .compressed: restoreMessage(failure: "The file is compressed. Run gunzip on it first.")
        case .notComplete: restoreMessage(failure: "The file is not a complete tar archive.")
        case .unsafeEntry(let path): restoreMessage(failure: "The file has an unsafe entry: \(path).")
        }
    }

    /// The text with a full stop at its end.
    nonisolated static func sentence(_ text: String) -> String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.hasSuffix(".") || t.hasSuffix("!") ? t : t + "."
    }
}
