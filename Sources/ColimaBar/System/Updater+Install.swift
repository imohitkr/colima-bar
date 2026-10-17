import AppKit
import Foundation
import os

/// The in-app install (see ARCHITECTURE.md, "In-app update"). Every step
/// before the swap can stop the update, and none of them changes the
/// Applications folder.
extension Updater {
    /// What a click on the update button does, for each kind of offer.
    func startUpdate() async {
        guard let release = available, phase == .idle else { return }
        switch offer {
        case .install:
            await confirmInstall(release)
        case .homebrew:
            switch UpdateAlert.homebrew(version: release.version) {
            case .copy:
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(Self.brewCommand, forType: .string)
            case .terminal:
                Shell.inTerminal(Self.brewCommand)
            case .cancel:
                break
            }
        case .link(let why):
            if UpdateAlert.link(version: release.version, current: AppDelegate.version, reason: why) {
                openReleasePage()
            }
        }
    }

    static let brewCommand = "brew upgrade --cask colima-bar && open -a ColimaBar"

    private func confirmInstall(_ release: ReleaseInfo) async {
        if let why = UpdatePolicy.blocker(activity()) {
            UpdateAlert.info("ColimaBar cannot restart now", "\(why). Try again when it ends.")
            return
        }
        let skip = await AttestationCheck.skipReason()
        // The state can change while gh runs.
        guard phase == .idle, available == release else { return }
        switch UpdateAlert.confirmInstall(version: release.version, current: AppDelegate.version, attestationSkip: skip)
        {
        // Only a user who read "cannot check" agrees to an install without it.
        case .install: install(allowAttestationSkip: skip != nil)
        case .notes: NSWorkspace.shared.open(release.page)
        case .cancel: break
        }
    }

    /// Starts the download. Does nothing in a debug run or for a copy that
    /// cannot update itself (see `UpdatePolicy.installTarget`).
    /// `allowAttestationSkip` is true only if the dialog said that `gh`
    /// cannot check the attestation. If it said that ColimaBar checks it,
    /// the update stops when the check cannot run later.
    func install(allowAttestationSkip: Bool = false) {
        guard let release = available, let zip = release.zip,
            let target = UpdatePolicy.installTarget(
                isDebug: AppDelegate.isDebugRun, isIdle: phase == .idle, fellBack: fellBack, source: source,
                hasZip: true)
        else { return }
        phase = .downloading(0)
        installTask = Task { [weak self] in
            await self?.runInstall(
                release, zip: zip, target: target.path, allowAttestationSkip: allowAttestationSkip)
        }
    }

    /// Cancels the download, the check or the wait. A running check tool
    /// gets SIGTERM. After the swap there is no way back.
    func cancel() {
        download?.cancel()
        installTask?.cancel()
    }

    private func runInstall(
        _ release: ReleaseInfo, zip: ReleaseInfo.Asset, target: String, allowAttestationSkip: Bool
    ) async {
        let tag = release.tag
        do {
            try await installSteps(release, zip: zip, target: target, allowAttestationSkip: allowAttestationSkip)
        } catch {
            // A cancel wins: a step that a cancel stopped can end with
            // another error, and that must not show.
            fail(UpdateError.ending(error, cancelled: Task.isCancelled), release: release)
        }
        log.notice("install of \(tag, privacy: .public) ended")
    }

    /// Ends an install with an error. The phase goes back to idle. The work
    /// folder goes, except after `rollbackFailed`: there it can hold the old
    /// bundle, so the next launch keeps it too (`Defaults.Key.recoveryPath`).
    func fail(_ error: UpdateError, release: ReleaseInfo) {
        Defaults.remove(.installedVersion)
        download = nil
        installTask = nil
        phase = .idle
        if case .rollbackFailed(let path) = error {
            Defaults.set(path, .recoveryPath)
        } else {
            removeWorkFolder()
        }
        let plan = UpdatePolicy.afterFailure(error)
        guard plan.notify else { return }
        log.error("update to \(release.tag, privacy: .public) failed: \(error.message, privacy: .public)")
        if let why = plan.fellBack { fellBack = why }
        announce(
            "ColimaBar did not install \(release.version). \(error.message) Click to open the release page.",
            "Update failed", release.page)
    }

    /// A restart that began did not work (a copy that was started by hand
    /// could not open the new instance). The new bundle is in place and this
    /// copy still runs. The button must not offer the same install again.
    func relaunchDidFail() {
        let version = available?.version
        phase = .idle
        guard let version else { return }
        finishWithoutRestart(version: version)
    }

    private func finishWithoutRestart(version: String) {
        available = nil
        restartPending = version
        announce(
            UpdatePolicy.restartNotice(version: version), "Update installed", ReleaseLink.page(tag: "v\(version)"))
    }

    private func installSteps(
        _ release: ReleaseInfo, zip: ReleaseInfo.Asset, target: String, allowAttestationSkip: Bool
    ) async throws {
        let running = AppDelegate.version
        guard let url = ReleaseLink.download(tag: release.tag) else {
            throw UpdateError.network("the tag is not valid")
        }
        let free = Self.freeSpace(Paths.cacheDir)
        guard free.map({ UpdatePolicy.hasRoom(free: $0, zipSize: zip.size) }) ?? true else {
            throw UpdateError.notEnoughSpace
        }
        let folder = try makeWorkFolder()

        // 1. Download.
        let dl = UpdateDownload(
            url: url, expectedSize: zip.size, file: folder.appendingPathComponent("ColimaBar.zip"),
            userAgent: "ColimaBar/\(running)"
        ) { share in
            Task { @MainActor in
                if case .downloading = Updater.shared.phase { Updater.shared.phase = .downloading(share) }
            }
        }
        download = dl
        let output = try await dl.run()
        download = nil
        try Task.checkCancellation()

        // 2. Verify. Nothing in the Applications folder has changed yet.
        phase = .verifying
        let verified = try await UpdateVerifier.verify(
            download: output, asset: zip, tag: release.tag, running: running, folder: folder,
            allowAttestationSkip: allowAttestationSkip)
        log.notice(
            "verified \(release.tag, privacy: .public); attestation: \(String(describing: verified.attestation), privacy: .public)"
        )
        try Task.checkCancellation()

        // 3. Get the copy ready beside the target (a copy to another volume
        // takes time, so it runs before the last busy check).
        let sameVolume = BundleSwap.onSameVolume(verified.app.path, target)
        let staged = try await offMain {
            try BundleSwap.prepare(target: target, unpacked: verified.app.path, sameVolume: sameVolume, ops: .live)
        }

        // 4. Wait until nothing busy runs, then swap and restart in one step
        // on the main actor, with no await between the last check and the swap.
        // Any error from here on leaves no staged copy in the Applications
        // folder (`BundleSwap.discard`), except after a failed rollback.
        do {
            try await waitAndCommit(release, target: target, staged: staged)
        } catch {
            BundleSwap.discard(staged: staged, unpacked: verified.app.path, after: error, ops: .live)
            throw error
        }
    }

    private func waitAndCommit(_ release: ReleaseInfo, target: String, staged: String) async throws {
        let started = Date()
        while true {
            try Task.checkCancellation()
            if let why = UpdatePolicy.blocker(activity()) {
                if Date().timeIntervalSince(started) > UpdatePolicy.maxWait { throw UpdateError.blocked(why) }
                phase = .waiting(why)
                try await Task.sleep(for: .seconds(2))
                continue
            }
            phase = .installing
            Defaults.set(release.version, .installedVersion)
            do {
                try BundleSwap.commit(
                    target: target, staged: staged, previous: updateDir + "/previous/ColimaBar.app",
                    expectedVersion: release.version, ops: .live)
            } catch {
                Defaults.remove(.installedVersion)
                throw error
            }
            installTask = nil
            if !relaunch() {
                // The new bundle is in place. The old copy keeps running.
                phase = .idle
                finishWithoutRestart(version: release.version)
            }
            return
        }
    }

    /// An empty work folder `update/<uuid>` (mode 0700). Older leftovers go first.
    private func makeWorkFolder() throws -> URL {
        let fm = FileManager.default
        removeWorkFolder()
        let folder = URL(fileURLWithPath: updateDir).appendingPathComponent(UUID().uuidString)
        do {
            try fm.createDirectory(
                atPath: Paths.cacheDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try fm.createDirectory(
                at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } catch {
            log.error("cannot create the work folder: \(error.localizedDescription, privacy: .public)")
            throw UpdateError.other("ColimaBar could not create its work folder (\(error.localizedDescription))")
        }
        return folder
    }

    /// Removes the work folder, except while it holds the old bundle of a
    /// failed rollback (`Defaults.Key.recoveryPath`): a new install must not
    /// delete the only good copy.
    func removeWorkFolder() {
        if let keep = Defaults.string(.recoveryPath), keep.hasPrefix(updateDir + "/"),
            FileManager.default.fileExists(atPath: keep)
        {
            log.notice("keeping the work folder: it holds the old bundle at \(keep, privacy: .public)")
            return
        }
        removeLogged(updateDir)
    }

    /// Removes `path`. A path that is already gone is no problem; any other
    /// failure goes to the log.
    private func removeLogged(_ path: String) {
        do { try FileManager.default.removeItem(atPath: path) } catch let e as CocoaError
            where e.code == .fileNoSuchFile
        {
            // Already gone.
        } catch {
            log.error("cannot remove \(path, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func freeSpace(_ path: String) -> Int64? {
        let url = URL(fileURLWithPath: path)
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    private func offMain<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(with: Result { try body() })
            }
        }
    }

    /// At launch, after an in-app update: if the running version is the one
    /// that the update installed, post one notification. In every case remove
    /// the key and the work folder (the download, the unpacked copy and the
    /// previous version). A copy to another volume can also leave
    /// `.ColimaBar-update.app` or `.ColimaBar-old.app` beside the bundle.
    func finishInstall() {
        let installed = Defaults.string(.installedVersion)
        if AppDelegate.installedNoticeDue(installed: installed, running: AppDelegate.version) {
            Notifier.shared.post(
                "ColimaBar \(AppDelegate.version) is installed. Click for the release notes.",
                title: "Update installed", record: false, url: ReleaseLink.page(tag: "v\(AppDelegate.version)"))
        }
        if installed != nil { Defaults.remove(.installedVersion) }
        if case .selfUpdate(let bundle) = source {
            cleanUp(bundle: bundle.path, running: Bundle.main.bundlePath)
        } else {
            cleanUp(bundle: nil, running: Bundle.main.bundlePath)
        }
    }

    /// Removes the work folder and the leftover copies beside `bundle`. It
    /// keeps everything while the old bundle of a failed rollback still
    /// exists (`Defaults.Key.recoveryPath`), and never removes `running`.
    func cleanUp(bundle: String?, running: String) {
        if let keep = Defaults.string(.recoveryPath) {
            if FileManager.default.fileExists(atPath: keep) {
                log.notice("keeping the old bundle at \(keep, privacy: .public)")
                return
            }
            Defaults.remove(.recoveryPath)
        }
        removeWorkFolder()
        guard let bundle else { return }
        for path in UpdatePolicy.leftovers(bundle: bundle) where path != running { removeLogged(path) }
    }
}
