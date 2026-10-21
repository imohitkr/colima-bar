import Foundation

/// The Cleanup page: log sizes, the disk image, Return Free Space and the
/// weekly cleanup. The rows of Docker come from `applyDF`.
extension ColimaModel {
    /// A log check does not run again within this time, unless forced.
    static let logSizesMinGap: TimeInterval = 60

    /// True if Return Free Space can start now.
    var canTrim: Bool {
        !isDebug && !updateRestarting && state == .running && busy == nil && !isTrimming && !hasActionInFlight
    }

    /// Reads the log sizes of the selected profile. It runs only while the VM
    /// runs, one at a time, and not again within 60 s unless `force`. It only
    /// reads, so a debug run may run it.
    func refreshLogSizes(force: Bool = false) async {
        guard state == .running, hasDockerSocket, !logSizesChecking, !cleanupFixtureLoaded else { return }
        if !force, let last = logSizesCheckedAt, Date().timeIntervalSince(last) < Self.logSizesMinGap { return }
        let gen = generation
        let p = profile
        setLogSizesChecking(true)
        let result = await logProbe(p)
        // A cancel (Done, a profile switch) is no failure: show nothing new.
        guard gen == generation, !Task.isCancelled, result != .cancelled, !cleanupFixtureLoaded else {
            // A newer check owns the flag after a generation change.
            if gen == generation { setLogSizesChecking(false) }
            return
        }
        logSizesCheckedAt = Date()
        switch result {
        case .sizes(let sizes):
            setLogSizes(sizes, error: nil)
        case .failed(let detail):
            var text = "ColimaBar could not read the log files in the VM. Check the VM and the sudo access in it."
            if !detail.isEmpty { text += " (\(detail))" }
            setLogSizes(logSizes, error: text)
        case .cancelled:
            break
        }
        setLogSizesChecking(false)
    }

    /// Measures the disk image of the selected profile off the main thread.
    func refreshDiskImage() async {
        guard !cleanupFixtureLoaded else { return }
        let gen = generation
        let size = await CleanupProbe.diskImage(profile: profile)
        guard gen == generation, !cleanupFixtureLoaded else { return }
        setDiskImage(size)
    }

    /// Empties the log of one container after the script asked.
    func truncateLog(_ item: CleanupItem) {
        guard !isDebug, !updateRestarting, item.kind == .log, let removal = item.removal else { return }
        dismissPopover()
        let p = profile
        Task {
            if await execute(removal.action, removal.args, profile: p, label: nil, expectRunning: true) {
                await refreshLogSizes(force: true)
            }
        }
    }

    /// Return Free Space: fstrim in the VM, then the before and after notification.
    func trimDisk() {
        guard canTrim else { return }
        setTrimming(true)
        let p = profile
        Task {
            let before = await CleanupProbe.diskImage(profile: p)
            let r = await executeResult(.diskTrim, [], profile: p, label: nil, expectRunning: true)
            // Exit 1 and 2: the script and `executeResult` already told the user.
            if r.status == 0 {
                try? await Task.sleep(for: DiskTrim.settleDelay)
                let after = await CleanupProbe.diskImage(profile: p)
                notify(
                    DiskTrim.message(
                        profile: p, trimmed: DiskTrim.trimmedBytes(in: r.out), before: before, after: after))
                if p == profile { setDiskImage(after) }
            }
            setTrimming(false)
        }
    }

    /// The weekly cleanup. `checkScheduledPrune` calls it.
    func runScheduledPrune(_ p: String) {
        Task {
            let r = await executeResult(.autoPrune, [], profile: p, label: nil, expectRunning: true)
            let now = Date()
            if PruneSchedule.countsAsRun(status: r.status) { savePruneRun(p, at: now) }
            // A failure waits longer than a busy VM. A good run needs no wait.
            pruneRetryAt[p] = PruneSchedule.retryAt(afterStatus: r.status, now: now)
        }
    }

    /// Debug runs only: shows a fixture file on the Cleanup page. Returns
    /// false in a normal run, or when the file is not a fixture.
    @discardableResult
    func loadCleanupFixture(_ data: Data) -> Bool {
        guard isDebug, let fixture = try? JSONDecoder().decode(CleanupFixture.self, from: data) else { return false }
        cleanupFixtureLoaded = true
        applyDF(fixture.df)
        setLogSizes(fixture.logs, error: nil)
        setDiskImage(fixture.diskImage.map { DiskImageSize(allocated: $0.allocated, apparent: $0.apparent) })
        return true
    }
}

/// The file of `COLIMABAR_CLEANUP_FIXTURE`: the raw body of `GET /system/df`,
/// the log sizes by container ID and the disk image sizes.
private struct CleanupFixture: Decodable {
    struct Disk: Decodable {
        let allocated: Int64
        let apparent: Int64
    }
    let df: APIDF
    let logs: [String: Int64]?
    let diskImage: Disk?
}
