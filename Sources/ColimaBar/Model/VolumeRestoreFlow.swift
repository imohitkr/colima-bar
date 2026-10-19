import Foundation

/// The steps of a restore, in order: the helper image, the target volume,
/// the rules of `VolumeRestorePlan`, then the upload. Nothing changes before
/// the checks pass. `ColimaModel` runs it and shows the result.
enum VolumeRestoreFlow {
    /// What a stopped restore changed.
    enum Change: Equatable {
        case nothing
        /// The new volume that this run made is gone again.
        case newVolumeRemoved
        /// The volume can hold part of the files.
        case partial
    }

    enum Outcome: Equatable {
        case done
        /// The user answered no to the replace question.
        case declined
        case cancelled(Change)
        /// Containers use the volume, or its driver options forbid a replace.
        /// The text is the notification.
        case refused(String)
        case failed(String)
        /// A problem that the user must know about, with its full notification
        /// text: the old files are gone, or a new volume stays.
        case notice(String)
    }

    /// `isNew` is true for Restore to New Volume: the volume must not exist,
    /// and a failed restore removes the volume that this run created.
    /// `willSend` runs right before the upload starts.
    @MainActor
    static func run(
        runner: VolumeBackupRunner, file: String, scan: TarFileScan.Summary, target: String, isNew: Bool,
        confirmReplace: @MainActor (String) -> Bool, willSend: @MainActor () -> Void,
        onProgress: @escaping @Sendable (Int64) -> Void
    ) async -> Outcome {
        let fileName = (file as NSString).lastPathComponent
        func failed(_ f: VolumeBackupRunner.Failure, cancel: Change = .nothing) -> Outcome {
            f.cancelled ? .cancelled(cancel) : .failed(f.reason)
        }
        if let f = await runner.prepare() { return failed(f) }
        var createdHere = false
        var deletedOld = false
        /// Stops a restore that made a new volume: the volume goes away again.
        func dropNew(_ f: VolumeBackupRunner.Failure) async -> Outcome {
            if await runner.deleteVolume(target) != nil {
                return .notice(
                    ColimaModel.restoreMessage(
                        file: fileName, stoppedBecause: f.cancelled ? nil : f.reason, keptNewVolume: target))
            }
            return failed(f, cancel: .newVolumeRemoved)
        }
        switch await runner.lookup(target) {
        case .failed(let f):
            return failed(f)
        case .missing:
            guard isNew else { return .failed("The volume does not exist any more.") }
            let labels = scan.meta?.labels(forTarget: target) ?? [:]
            if let f = await runner.createVolume(target, labels: labels) { return failed(f) }
            // Docker answers a create of an existing volume with success. So the
            // volume is new only if it has no user and no file.
            let users = await runner.users(of: target, runningOnly: false)
            let empty = await runner.isEmpty(volume: target)
            if let users, !users.isEmpty { return .refused(ColimaModel.restoreMessage(volumeExistsNow: target)) }
            if case .success(false) = empty { return .refused(ColimaModel.restoreMessage(volumeExistsNow: target)) }
            guard users != nil, case .success = empty else {
                // ColimaBar cannot prove that it made the volume, so it does not delete it.
                var reason: String? = "Docker did not answer."
                if case .failure(let f) = empty { reason = f.cancelled ? nil : f.reason }
                return .notice(
                    ColimaModel.restoreMessage(file: fileName, stoppedBecause: reason, keptNewVolume: target))
            }
            createdHere = true
        case .found(let info):
            guard !isNew else { return .failed("A volume named \(target) exists.") }
            guard let users = await runner.users(of: target, runningOnly: false) else {
                return .failed("Docker did not answer.")
            }
            let empty: Bool
            switch await runner.isEmpty(volume: target) {
            case .success(let e): empty = e
            case .failure(let f): return failed(f)
            }
            if runner.isCancelled { return .cancelled(.nothing) }
            switch VolumeRestorePlan.decide(exists: true, isEmpty: empty, users: users) {
            case .refuse(let names):
                return .refused(ColimaModel.restoreMessage(volume: target, users: names))
            case .confirmReplace:
                // A bind folder or an NFS volume cannot come back from a delete and a create.
                guard info.isPlain else { return .refused(ColimaModel.restoreMessage(driverOptionsOf: target)) }
                guard confirmReplace(target) else { return .declined }
                if runner.isCancelled { return .cancelled(.nothing) }
                // The volume keeps its own labels: the file can come from another volume.
                if let f = await runner.deleteVolume(target) { return failed(f) }
                deletedOld = true
                if let f = await runner.createVolume(target, labels: info.Labels ?? [:]) {
                    return .notice(
                        ColimaModel.restoreMessage(
                            file: fileName, volume: target, deletedOld: true, state: .gone,
                            reason: f.cancelled ? nil : f.reason))
                }
            case .useEmpty, .createNew:
                break
            }
        }
        willSend()
        let failure = await runner.restore(
            file: file, skip: scan.skip, size: scan.size, into: target, onProgress: onProgress)
        guard let failure else { return .done }
        // A volume that this restore created has no value without its files.
        if createdHere { return await dropNew(failure) }
        if deletedOld {
            return .notice(
                ColimaModel.restoreMessage(
                    file: fileName, volume: target, deletedOld: true, state: .partial,
                    reason: failure.cancelled ? nil : failure.reason))
        }
        return failed(failure, cancel: .partial)
    }
}
