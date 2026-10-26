import Foundation

/// The image update check. A local pass compares the image of each container
/// with the image of its tag, with no registry call. A registry pass asks
/// for the digest of each tag, at most once a day (`ImageUpdateSchedule`).
/// Every call goes to the Colima socket of the selected profile, so none of
/// them starts the VM. A debug run makes no registry call and pulls nothing.
extension ColimaModel {
    // MARK: - Setting

    /// Called after the setting changed. Off forgets the results and the
    /// waits. The cache stays, so turning it on again needs no new calls.
    func imageUpdateSettingChanged() {
        if imageUpdateCheck {
            scheduleImageUpdateScan()
        } else {
            imageRunAt = [:]
            imageCheckNowAt = nil
            imageChecking = false
            resetImageUpdates()
        }
    }

    /// Forgets what the daemon said, and the results. A new scan starts with
    /// the next container refresh.
    func resetImageUpdates() {
        imageScan = ImageUpdateRunner.Scan()
        imageScanning = false
        imageScanAgain = false
        imageChecking = false
        setImageUpdates(ImageUpdateState(pulling: imagePulls[profile] ?? []))
    }

    /// Removes the answers of the profiles that `colima list` no longer shows.
    func pruneImageUpdateCache(keeping listed: Set<String>) {
        guard !isDebug, !listed.isEmpty else { return }
        let busy = Set(imageUpdateCache.profiles.keys.filter { busyMarker(of: $0) != nil })
        let pruned = imageUpdateCache.pruned(keeping: listed, busy: busy)
        guard pruned != imageUpdateCache else { return }
        imageUpdateCache = pruned
        saveImageUpdateCache()
    }

    func saveImageUpdateCache() {
        guard !isDebug else { return }
        domainsStore.set(imageUpdateCache.json, forKey: Defaults.Key.imageUpdateCache.rawValue)
    }

    // MARK: - Local pass

    /// Starts a scan of the images, off the caller's task. It does nothing
    /// while the setting is off.
    func scheduleImageUpdateScan() {
        guard imageUpdateCheck else { return }
        Task { await refreshImageUpdates() }
    }

    /// Reads the image of each container and of each tag from the daemon, and
    /// builds the results. One scan runs at a time. A request during a scan
    /// runs it again. A debug run with a fixture keeps the fixture's results.
    func refreshImageUpdates() async {
        guard imageUpdateCheck, hasDockerSocket, state == .running else { return }
        guard !imageScanning else {
            imageScanAgain = true
            return
        }
        imageScanning = true
        let gen = generation
        // A profile switch resets the flag. An older scan then must not touch it.
        defer { if gen == generation { imageScanning = false } }
        repeat {
            imageScanAgain = false
            let runner = ImageUpdateRunner(api: api)
            let scan = await runner.scan(containerIDs: containers.map(\.id), known: imageScan.configImages)
            guard gen == generation, imageUpdateCheck, state == .running, let scan else { return }
            imageScan = scan
            trimImageUpdateCache()
            rebuildImageUpdates()
        } while imageScanAgain
    }

    /// Removes the answers for references that no container uses. An empty
    /// container list can be a start in progress, so it removes nothing.
    private func trimImageUpdateCache() {
        guard !isDebug, !containers.isEmpty, !imageScan.configImages.isEmpty else { return }
        let keys = Set(
            imageScan.configImages.values.compactMap { (try? ImageUpdateCheck.reference(of: $0).get())?.normalized })
        let trimmed = imageUpdateCache.trimmed(profile: profile, keeping: keys)
        guard trimmed != imageUpdateCache else { return }
        imageUpdateCache = trimmed
        saveImageUpdateCache()
    }

    /// Builds the results from the last scan and the cache.
    func rebuildImageUpdates() {
        setImageUpdates(
            ImageUpdateState.make(
                containers: containers, configImages: imageScan.configImages, local: imageScan.images,
                entries: imageUpdateCache.entries(of: profile), checking: imageChecking,
                pulling: imagePulls[profile] ?? []))
    }

    // MARK: - Registry pass

    /// Starts a registry check when one is due. `tick` calls it.
    func checkImageUpdates() {
        guard let refs = claimImageUpdates(now: Date()) else { return }
        runImageUpdateCheck(refs, now: Date())
    }

    /// True if Check Now can start. The button reads it.
    var canCheckImagesNow: Bool {
        imageUpdateCheck && !isDebug && !imageChecking && state == .running
            && ImageUpdateSchedule.checkNowAllowed(last: imageCheckNowAt, now: Date())
    }

    /// Check Now: checks the oldest references again, within the limits of one run.
    func checkImagesNow() {
        let now = Date()
        guard canCheckImagesNow, let refs = claimImageUpdates(now: now, force: true) else { return }
        imageCheckNowAt = now
        runImageUpdateCheck(refs, now: now)
    }

    private func runImageUpdateCheck(_ refs: [ImageRef], now: Date) {
        imageChecking = true
        rebuildImageUpdates()
        let gen = generation
        let p = profile
        let runner = ImageUpdateRunner(api: api)
        Task {
            let answers = await runner.check(refs, now: now)
            // A profile switch has reset the flag and the results.
            guard gen == generation else { return }
            imageChecking = false
            if imageUpdateCheck { applyImageAnswers(answers, profile: p) }
            rebuildImageUpdates()
            // Counts only: the references name the user's images.
            log.notice(
                "image update check: \(answers.count, privacy: .public) answers, \(answers.values.filter { $0.error != nil }.count, privacy: .public) failed"
            )
        }
    }

    /// Merges the answers of a run into the cache of `p`. A digest that a
    /// pull already took keeps its pulled mark.
    func applyImageAnswers(_ answers: [String: ImageUpdateCache.Entry], profile p: String) {
        var entries = imageUpdateCache.entries(of: p)
        for (key, answer) in answers {
            var entry = answer
            if let old = entries[key], old.pulled == true, old.digest == entry.digest { entry.pulled = true }
            entries[key] = entry
        }
        imageUpdateCache.set(entries, profile: p)
        saveImageUpdateCache()
    }

    // MARK: - Pull

    /// True if ColimaBar may pull now. A debug run pulls nothing.
    var canPullImages: Bool {
        !isDebug && !updateRestarting && state == .running && hasDockerSocket
    }

    /// Pulls the tags in `refs` of the selected profile, one after the other,
    /// and returns true if all were pulled. A failed pull sends a notification.
    /// Then the container list and the disk use are read again.
    @discardableResult
    func pullImages(_ refs: [ImageRef]) async -> Bool {
        guard canPullImages else { return false }
        let p = profile
        let gen = generation
        let runner = ImageUpdateRunner(api: api)
        let todo = refs.filter { !(imagePulls[p]?.contains($0.normalized) ?? false) }
        guard !todo.isEmpty else { return false }
        setPulling(todo.map(\.normalized), on: true, profile: p)
        defer { setPulling(todo.map(\.normalized), on: false, profile: p) }
        let host = await runner.hostArchitecture()
        var allPulled = true
        for ref in todo {
            guard gen == generation else { return false }
            let platform = imageScan.images[ref.normalized].flatMap {
                ImageUpdateCheck.platform(of: $0, hostArchitecture: host)
            }
            switch await runner.pull(ref, platform: platform) {
            case .pulled:
                markPulled(ref, profile: p)
            case .failed(_, let message):
                allPulled = false
                notify("Pull failed for \(ref.normalized): \(ImageUpdateCheck.shortened(message))")
            case .cancelled:
                allPulled = false
            }
        }
        if gen == generation {
            await refreshContainers()
            requestDF(urgent: true)
        }
        return allPulled
    }

    private func markPulled(_ ref: ImageRef, profile p: String) {
        var entries = imageUpdateCache.entries(of: p)
        guard var entry = entries[ref.normalized], entry.digest != nil else { return }
        entry.pulled = true
        entries[ref.normalized] = entry
        imageUpdateCache.set(entries, profile: p)
        saveImageUpdateCache()
    }

    private func setPulling(_ keys: [String], on: Bool, profile p: String) {
        var set = imagePulls[p] ?? []
        if on { set.formUnion(keys) } else { set.subtract(keys) }
        imagePulls[p] = set.isEmpty ? nil : set
        if p == profile {
            var state = imageUpdates
            state.pulling = set
            setImageUpdates(state)
        }
    }

    /// The row action: pulls the new image of one container.
    func pullNewImage(containerID id: String) {
        guard let ref = imageRef(ofContainer: id), imageUpdates.containers[id]?.isUpdate == true else { return }
        Task { await pullImages([ref]) }
    }

    /// The strip action: pulls every image with an update.
    func pullAllImageUpdates() {
        let refs = imageUpdates.updateRefs
        guard !refs.isEmpty else { return }
        Task { await pullImages(refs) }
    }

    private func imageRef(ofContainer id: String) -> ImageRef? {
        imageScan.configImages[id].flatMap { (try? ImageUpdateCheck.reference(of: $0).get()) }
    }

    // MARK: - Compose

    /// True when a container of the project shows an update or a recreate.
    func projectNeedsUpdate(_ project: String) -> Bool {
        imageUpdateCheck
            && containers.contains { c in
                c.project == project && (imageUpdates.badge(for: c) != nil)
            }
    }

    /// Pulls the updated images of a Compose project, then runs `docker
    /// compose up -d`. That command creates only the services that changed.
    func updateAndRecreate(project: ComposeProject) {
        let key = composeKey(project)
        guard canPullImages, !composeBusy.contains(key) else { return }
        let members = containers.filter { $0.project == project.name }
        let refs = imageUpdates.updateRefs(of: members, configImages: imageScan.configImages)
        setComposeBusy(composeBusy.union([key]))
        let p = profile
        Task {
            let pulled = refs.isEmpty ? true : await pullImages(refs)
            setComposeBusy(composeBusy.subtracting([key]))
            if pulled, p == profile { compose(.up, project: project) }
        }
    }

    // MARK: - Debug fixture

    /// Debug runs only: stands for the registry. The file is
    /// `{"results": {"nginx:latest": {"digest": "sha256:…"}, "ghcr.io/x/y:1": {"error": "signInNeeded"}}}`.
    /// It writes no cache. Returns false in a normal run, or when the file is not a fixture.
    @discardableResult
    func loadImageUpdateFixture(_ data: Data) -> Bool {
        guard isDebug, let fixture = try? JSONDecoder().decode(ImageUpdateFixture.self, from: data) else {
            return false
        }
        var entries: [String: ImageUpdateCache.Entry] = [:]
        let now = Date()
        for (text, result) in fixture.results {
            guard let ref = ImageRef.parse(text) else { continue }
            if let digest = result.digest, digest.hasPrefix("sha256:") {
                entries[ref.normalized] = .init(digest: digest, checkedAt: now)
            } else if let error = result.error.flatMap(ImageUpdateStatus.Failure.init(rawValue:)) {
                entries[ref.normalized] = .init(error: error, checkedAt: now)
            }
        }
        imageUpdateCache.set(entries, profile: profile)
        imageUpdateCheck = true
        rebuildImageUpdates()
        scheduleImageUpdateScan()
        return true
    }
}

/// The file of `COLIMABAR_IMAGE_UPDATES_FIXTURE`.
private struct ImageUpdateFixture: Decodable {
    struct Result: Decodable {
        let digest: String?
        let error: String?
    }
    let results: [String: Result]
}
