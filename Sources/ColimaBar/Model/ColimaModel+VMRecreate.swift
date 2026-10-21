import Darwin
import Foundation

/// The guided change of the VM type and the mount type of the selected
/// profile: back up, recreate through `colima-ctl.sh vm-recreate`, restore.
/// `VMRecreateFlow` has the order of the steps. This file gives it the real
/// steps and shows the result. The model holds the actions of the profile for
/// the whole run, so auto-stop, the weekly cleanup and the checks after sleep
/// stay away. A debug run changes nothing.
extension ColimaModel {
    // MARK: - Rules

    /// The rule for a start: a normal run, no other action, no transfer, no
    /// other VM type change, no unfinished one, and a colima.yaml to change.
    nonisolated static func mayRecreate(
        isDebug: Bool, busy: Bool, transferring: Bool, recreating: Bool, hasConfig: Bool, hasPending: Bool = false
    ) -> Bool {
        !isDebug && !busy && !transferring && !recreating && hasConfig && !hasPending
    }

    var canRecreate: Bool { canRecreate(ignoringPending: false) }

    /// `ignoringPending` is for the restore of an unfinished change: the
    /// unfinished change itself must not block it.
    func canRecreate(ignoringPending: Bool) -> Bool {
        Self.mayRecreate(
            isDebug: isDebug, busy: busy != nil || hasActionInFlight, transferring: volumeTransfer != nil,
            recreating: recreate != nil, hasConfig: vmSettings != nil,
            hasPending: !ignoringPending && pendingRecreate[profile] != nil)
    }

    /// Why a VM type change cannot start now, or nil. A hint uses it.
    var recreateBlockReason: String? { recreateBlockReason(ignoringPending: false) }

    func recreateBlockReason(ignoringPending: Bool) -> String? {
        if canRecreate(ignoringPending: ignoringPending) { return nil }
        if isDebug { return Help.doctorDebug }
        if vmSettings == nil { return Help.recreateNoConfig }
        if !ignoringPending, recreate == nil, busy == nil, !hasActionInFlight, volumeTransfer == nil,
            pendingRecreate[profile] != nil
        {
            return Help.recreatePending
        }
        return Help.recreateBusy
    }

    /// What the plan and the confirmation need to know now.
    func recreateInputs(vmType: String, mountType: String) -> VMRecreatePlan.Inputs {
        VMRecreatePlan.Inputs(
            profile: profile, current: vmSettings ?? VMSettings.Read(), target: (vmType, mountType),
            running: state == .running, hasDockerSocket: hasDockerSocket,
            dataDiskKept: VMRecreatePlan.dataDiskKept(
                profile: profile, colimaDir: Paths.colimaDir, limaDir: Paths.limaDir),
            volumes: volumes, images: images)
    }

    // MARK: - Start

    /// Runs the whole change for the selected profile. `parent` is the folder
    /// that the user chose for the backups. It is nil if `backUp` and
    /// `saveImages` are both false. The alert checked the free space.
    func startRecreate(vmType: String, mountType: String, backUp: Bool, saveImages: Bool, parent: URL?) {
        let p = profile
        guard !isDebug, !updateRestarting else { return }
        if let reason = recreateBlockReason {
            notify(reason)
            return
        }
        guard VMTypeRules.isValid(vmType: vmType, mountType: mountType) else { return }
        let inputs = recreateInputs(vmType: vmType, mountType: mountType)
        let plan = VMRecreatePlan.make(inputs)
        // The alert offers a backup only while a docker VM runs. If that changed, do not drop the choice.
        if (backUp || saveImages) && (!plan.canBackUp || parent == nil) {
            notify(
                "ColimaBar cannot back up now, so nothing changed. Start the VM, or choose no backup, and try again.")
            return
        }
        let volumesToSave = backUp ? plan.volumes : []
        let imagesToSave = saveImages ? plan.imageRefs : []
        let running = isRunning(profile: p)
        let from = VMTypeRules.effective(vmType: inputs.current.vmType, mountType: inputs.current.mountType)
        holdAction(p)
        setRecreate(VMRecreateProgress(profile: p, step: .preparing))
        Task {
            await runRecreate(
                p, from: from, to: (vmType, mountType), volumes: volumesToSave, images: imagesToSave,
                parent: parent, running: running, plan: plan)
        }
    }

    private func runRecreate(
        _ p: String, from: (vmType: String, mountType: String), to: (vmType: String, mountType: String),
        volumes: [VolumeRow], images: [String], parent: URL?, running: Bool, plan: VMRecreatePlan
    ) async {
        var folder: URL?
        if recreate?.isCancelling == true {
            notify("Stopped. Nothing changed.")
            await endRecreate(p)
            return
        }
        if (!volumes.isEmpty || !images.isEmpty), let parent {
            switch Self.makeBackupFolder(parent: parent, profile: p, date: Date()) {
            case .success(let url): folder = url
            case .failure(let error):
                notify("Backup failed, so nothing changed: \(Self.sentence(error.reason))")
                await endRecreate(p)
                return
            }
        }
        let journal = VMRecreateJournal(
            profile: p, from: .init(vmType: from.vmType, mountType: from.mountType),
            to: .init(vmType: to.vmType, mountType: to.mountType), folder: folder?.path ?? "", created: Date(),
            phase: .backup)
        let steps = recreateSteps(p, plan: plan, running: running)
        let outcome = await VMRecreateFlow.run(
            journal, folder: folder, backUp: volumes, saveImages: images, restop: !running, steps: steps)
        finishRecreate(outcome, journal: journal, restop: !running)
        if let folder {
            switch outcome {
            case .nothingChanged, .cancelledBeforeChange: Self.removeEmptyFolder(folder)
            default: break
            }
        }
        await endRecreate(p)
    }

    /// Restores the volumes and images of a journal that are missing now. The
    /// user chose the backup folder in the panel.
    func resumeRecreate(_ p: String, folder: URL) {
        guard !isDebug, p == profile, state == .running, let journal = pendingRecreate[p] else { return }
        let read = (try? String(contentsOfFile: Paths.config(p), encoding: .utf8)).map(VMSettings.read)
        guard VMRecreateJournal.recovery(journal, now: read, busy: false) == .restorePending else { return }
        if let reason = recreateBlockReason(ignoringPending: true) {
            notify(reason)
            return
        }
        guard canTransferVolumes else {
            notify(transferBlockReason ?? Help.transferNeedsVM)
            return
        }
        holdAction(p)
        setRecreate(VMRecreateProgress(profile: p, step: .restoring))
        let plan = VMRecreatePlan.make(recreateInputs(vmType: journal.to.vmType, mountType: journal.to.mountType))
        Task {
            let steps = recreateSteps(p, plan: plan, running: true, writesCopy: false)
            let outcome = await VMRecreateFlow.resume(journal, folder: folder, steps: steps)
            finishRecreate(outcome, journal: journal, restop: false)
            await endRecreate(p)
        }
    }

    private func endRecreate(_ p: String) async {
        releaseAction(p)
        setRecreate(nil)
        imageRunner = nil
        loadRecreateJournals()
        await refreshAll(urgentDF: true)
    }

    // MARK: - Steps

    private func recreateSteps(
        _ p: String, plan: VMRecreatePlan, running: Bool, writesCopy: Bool = true
    ) -> VMRecreateFlow.Steps {
        let imageBytes = plan.imageBytes
        /// The docker API of the profile of the change, not of the selected one.
        func profileAPI() -> DockerAPI { profile == p ? api : DockerAPI(socketPath: Paths.socket(p)) }
        /// A runner that starts after a Cancel must stop at once.
        func armed<R>(_ runner: R, _ cancel: (R) -> Void) -> R {
            if recreate?.isCancelling == true { cancel(runner) }
            return runner
        }
        func stopReason() -> VolumeTransferStop? {
            if profile != p { return .profileChanged }
            // A VM that did not run before the change has nothing to wait for.
            return !running || state == .running ? nil : .vmStopped
        }
        func progress(_ update: @MainActor (inout VMRecreateProgress) -> Void) {
            guard var r = recreate else { return }
            update(&r)
            setRecreate(r)
        }
        return VMRecreateFlow.Steps(
            backUp: { [self] rows, folder in
                let names = VolumeBackupName.fileNames(for: rows.map { ($0.name, $0.isAnonymous) }, date: Date())
                return await performBackup(
                    volumes: rows, destinations: names.map { folder.appendingPathComponent($0) }, replace: false,
                    folder: folder.lastPathComponent, notifies: false, fromRecreate: true, api: profileAPI())
            },
            saveImages: { [self] refs, folder in
                let runner = armed(ImageArchiveRunner(api: profileAPI())) { $0.cancel() }
                imageRunner = runner
                progress { $0.total = imageBytes }
                let result = await runner.save(
                    refs: refs, to: folder.appendingPathComponent("images.tar").path,
                    onProgress: { [weak self] bytes in Task { @MainActor in self?.recreateBytes(bytes) } })
                imageRunner = nil
                return result
            },
            recreate: { [self] vmType, mountType in
                // The script shows a dialog, so the popover must not cover it.
                dismissPopover()
                let label = markBusy(.vmRecreate, p, running: running)
                return await executeResult(
                    .vmRecreate, [vmType, mountType], profile: p, label: label, expectRunning: running)
            },
            waitReady: { [self] in
                let ready = await ReadinessGate.wait(
                    probe: ReadinessGate.dockerProbe(socketPath: Paths.socket(p)), timeout: 120)
                // The restore needs the state of the model: wait for `running`.
                var tries = 0
                while ready, state != .running, tries < 20 {
                    await refreshAll()
                    if state == .running { break }
                    try? await Task.sleep(for: .seconds(1))
                    tries += 1
                }
                return ready && state == .running
            },
            readTypes: {
                guard let text = try? String(contentsOfFile: Paths.config(p), encoding: .utf8) else { return nil }
                let read = VMSettings.read(text)
                return VMTypeRules.effective(vmType: read.vmType, mountType: read.mountType)
            },
            stopReason: { stopReason() },
            isCancelled: { [self] in recreate?.isCancelling == true },
            restore: { [self] volume, folder in
                let url = folder.appendingPathComponent(volume.file)
                guard let scan = await scanBackup(file: url, notifies: false) else {
                    return .notice("the backup file is not readable")
                }
                // The scan awaited: the profile or the VM may have changed since the check of the flow.
                if stopReason() != nil { return .cancelled(.nothing) }
                progress { $0.volume = volume.name }
                return await performRestore(
                    file: url, scan: scan, target: volume.name, isNew: true, confirmReplace: { _ in false },
                    notifies: false, fromRecreate: true, api: profileAPI())
            },
            volumeExists: { name in
                switch await VolumeBackupRunner(api: profileAPI()).lookup(name) {
                case .found: true
                case .missing: false
                case .failed: nil
                }
            },
            missingImages: { refs in await ImageArchiveRunner(api: profileAPI()).missing(refs) },
            loadImages: { [self] file, sha in
                let runner = armed(ImageArchiveRunner(api: profileAPI())) { $0.cancel() }
                imageRunner = runner
                var st = stat()
                let size = stat(file.path, &st) == 0 ? Double(st.st_size) : 0
                progress {
                    $0.bytes = 0
                    $0.total = size
                }
                let failure = await runner.load(
                    file: file.path, sha256: sha,
                    onProgress: { [weak self] bytes in Task { @MainActor in self?.recreateBytes(bytes) } })
                imageRunner = nil
                return failure
            },
            saveJournal: { [self] journal in writeRecreateJournal(journal, writesCopy: writesCopy) },
            dropJournal: { [self] in dropRecreateJournal(p) },
            progress: { step in
                progress {
                    $0.step = step
                    if step != .backingUp, step != .restoring { $0.position = nil }
                    if step == .savingImages || step == .loadingImages { $0.bytes = 0 }
                }
            })
    }

    private func recreateBytes(_ bytes: Int64) {
        guard var r = recreate, r.step == .savingImages || r.step == .loadingImages, bytes > r.bytes else { return }
        r.bytes = bytes
        setRecreate(r)
    }

    // MARK: - Cancel and dismiss

    /// Stops the step that runs now: a backup or an image save before the
    /// change, or a restore after it. The script and the wait for Docker
    /// cannot stop.
    func cancelRecreate() {
        guard var r = recreate, r.canCancel else { return }
        r.isCancelling = true
        setRecreate(r)
        volumeRunner?.cancel()
        imageRunner?.cancel()
    }

    /// Deletes the journal of a profile. The backup folder stays.
    func dismissRecreate(_ p: String) {
        guard !isDebug, recreate?.profile != p else { return }
        dropRecreateJournal(p)
    }

    // MARK: - Journal

    /// Writes the journal to the cache folder, and a copy into the backup
    /// folder if `writesCopy` and the folder exists. False if the cache
    /// journal could not be written: then the VM must not change. The copy is
    /// a hint for the user. A failed copy is not an error.
    @discardableResult
    func writeRecreateJournal(_ journal: VMRecreateJournal, writesCopy: Bool = true) -> Bool {
        guard !isDebug else { return true }
        let data = journal.encoded()
        guard Self.writePrivate(data, to: recreateJournalPath(journal.profile), makeParent: true) else { return false }
        var isDir: ObjCBool = false
        if writesCopy, !journal.folder.isEmpty,
            FileManager.default.fileExists(atPath: journal.folder, isDirectory: &isDir), isDir.boolValue
        {
            _ = Self.writePrivate(data, to: journal.folder + "/recreate.json", makeParent: false)
        }
        return true
    }

    func recreateJournalPath(_ p: String) -> String { "\(recreateCacheDir)/recreate.\(p).json" }

    /// Deletes the journal in the cache folder. The `recreate.json` copy in the
    /// backup folder stays as it is: it is the record of the backup.
    private func dropRecreateJournal(_ p: String) {
        guard !isDebug else { return }
        try? FileManager.default.removeItem(atPath: recreateJournalPath(p))
        if pendingRecreate[p] != nil {
            var all = pendingRecreate
            all[p] = nil
            setPendingRecreate(all)
        }
    }

    /// Writes a file with the mode 0600 that replaces an older one. False on a failure.
    private static func writePrivate(_ data: Data, to path: String, makeParent: Bool) -> Bool {
        if makeParent {
            try? FileManager.default.createDirectory(
                atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
        }
        guard let writer = try? PrivateFileWriter(destination: path, replace: true) else { return false }
        do {
            try writer.write(data)
            try writer.commit()
            return true
        } catch {
            writer.abort()
            return false
        }
    }

    /// Reads the journals of the profiles that have a VM type change that
    /// did not finish. A profile with an action that runs now has none. A
    /// debug run reads nothing.
    func loadRecreateJournals() {
        guard !isDebug else { return }
        setPendingRecreate(
            Self.readRecreateJournals(
                in: recreateCacheDir,
                config: { try? String(contentsOfFile: Paths.config($0), encoding: .utf8) },
                isBusy: { [self] in busyMarker(of: $0) != nil || recreate?.profile == $0 }))
    }

    /// The journals in `dir` that need the user: `recreate.PROFILE.json` files
    /// whose name matches their profile, and that have a recovery. `config`
    /// gives the colima.yaml text of a profile.
    nonisolated static func readRecreateJournals(
        in dir: String, config: (String) -> String?, isBusy: (String) -> Bool
    ) -> [String: VMRecreateJournal] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
        var found: [String: VMRecreateJournal] = [:]
        for name in names where name.hasPrefix("recreate.") && name.hasSuffix(".json") {
            let path = "\(dir)/\(name)"
            guard let data = FileManager.default.contents(atPath: path), let j = VMRecreateJournal.load(data),
                "\(dir)/recreate.\(j.profile).json" == path
            else { continue }
            let read = config(j.profile).map(VMSettings.read)
            if VMRecreateJournal.recovery(j, now: read, busy: isBusy(j.profile)) != nil { found[j.profile] = j }
        }
        return found
    }

    // MARK: - Folder and texts

    /// Makes the backup folder `ColimaBar-PROFILE-yyyyMMdd-HHmmss` in `parent`
    /// with the mode 0700. `mkdir` fails if the name exists, so ColimaBar never
    /// writes into a folder that it did not make.
    nonisolated static func makeBackupFolder(
        parent: URL, profile: String, date: Date, timeZone: TimeZone = .current
    ) -> Result<URL, VolumeBackupRunner.Failure> {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = timeZone
        f.dateFormat = "yyyyMMdd-HHmmss"
        let url = parent.appendingPathComponent("ColimaBar-\(profile)-\(f.string(from: date))")
        guard mkdir(url.path, 0o700) == 0 else {
            return .failure(
                VolumeBackupRunner.failure(POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)))
        }
        return .success(url)
    }

    /// Removes the backup folder if the run wrote no backup file into it.
    nonisolated static func removeEmptyFolder(_ folder: URL) {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: folder.path),
            names.allSatisfy({ $0 == "recreate.json" })
        else { return }
        for name in names { try? fm.removeItem(atPath: folder.appendingPathComponent(name).path) }
        rmdir(folder.path)
    }

    private func finishRecreate(_ outcome: VMRecreateFlow.Outcome, journal j: VMRecreateJournal, restop: Bool) {
        let uses = "\(j.to.vmType) / \(j.to.mountType)"
        let head = "The VM of profile \(j.profile) now uses \(uses)."
        let named = j.folderName
        switch outcome {
        case .finished(let restored, let kept, let failed, let loaded):
            notify(
                Self.recreateMessage(
                    head: head, folder: named, restop: restop, restored: restored, kept: kept, failed: failed,
                    imagesLoaded: loaded))
        case .nothingChanged(let text), .restorePending(let text): if !text.isEmpty { notify(text) }
        case .cancelledBeforeChange:
            let kept = (try? FileManager.default.contentsOfDirectory(atPath: j.folder))?.contains {
                $0 != "recreate.json"
            }
            notify("Stopped. Nothing changed." + (kept == true ? " The backups so far are in \(named)." : ""))
        case .changedWithoutBackup: break  // the script told the user
        }
    }

    /// The notification for a finished change.
    nonisolated static func recreateMessage(
        head: String, folder: String, restop: Bool, restored: Int, kept: Int, failed: [String], imagesLoaded: Bool
    ) -> String {
        if !failed.isEmpty {
            return "\(head) Restore failed for: \(failed.joined(separator: ", ")). The backups are in \(folder)."
        }
        if restop { return "\(head) It is stopped again." }
        var parts: [String] = []
        if restored > 0 { parts.append("restored \(restored) volume\(restored == 1 ? "" : "s")") }
        if imagesLoaded { parts.append("loaded the images") }
        guard !parts.isEmpty else { return "\(head) Volumes and images are still there." }
        let text = parts.joined(separator: " and ")
        return "\(head) \(text.prefix(1).uppercased() + text.dropFirst()) from \(folder)."
    }

    // MARK: - Demo

    /// A debug run with COLIMABAR_RECREATE_DEMO=1: shows a fake progress. It
    /// runs nothing and writes nothing.
    func showRecreateDemo() {
        guard isDebug else { return }
        setRecreate(
            VMRecreateProgress(
                profile: profile, step: .backingUp, volume: "pgdata", bytes: 420 << 20, total: Double(1 << 30),
                position: 2, count: 5))
    }
}
