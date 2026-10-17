import Foundation

/// The upgrade guard: the record of the tool versions at the last good start
/// of each profile. See `UpgradeGuard` for the rules. A debug run never writes
/// the record.
extension ColimaModel {
    /// The records of good starts. A problem with the saved text goes in the
    /// log once per launch, without the content.
    func goodStarts() -> GoodStarts {
        let (all, problem) = GoodStarts.decodeChecked(Defaults.string(.goodStartVersions))
        if let problem, !goodStartsProblemLogged {
            goodStartsProblemLogged = true
            log.error("upgrade guard: \(problem, privacy: .public)")
        }
        return all
    }

    /// The versions at the last good start of a profile, or nil if none is recorded.
    func goodStart(for p: String) -> ToolVersions? { goodStarts().records[p] }

    /// Reads the versions of Colima and Lima. A tool that gives no version
    /// goes in the log, once per launch for each tool.
    func probeVersions() async -> ToolVersions {
        let (versions, problems) = await DoctorProbe.versions()
        for (tool, why) in problems.sorted(by: { $0.key < $1.key }) where upgradeProbeLogged.insert(tool).inserted {
            log.error("upgrade guard: no version of \(tool, privacy: .public): \(why, privacy: .public)")
        }
        return versions
    }

    /// Records the versions as the last good start. It saves only when the
    /// versions of Colima and Lima are known. Returns true if it saved or the
    /// record was the same.
    @discardableResult
    func saveGoodStart(_ versions: ToolVersions, _ p: String) -> Bool {
        guard !isDebug else { return false }
        guard UpgradeGuard.canSave(versions) else {
            log.notice("upgrade guard: versions unknown, no record for \(p, privacy: .public)")
            return false
        }
        var all = goodStarts()
        guard all.records[p] != versions else { return true }
        all.records[p] = versions
        Defaults.set(all.json, .goodStartVersions)
        return true
    }

    /// Gives each running profile that has no record the current versions,
    /// once per launch. A seed never replaces a record. Thus a user who
    /// installs this version gets no warning at the next start. If the probe
    /// gives no versions, the next refresh tries again.
    func seedGoodStarts() {
        guard !isDebug, !upgradeSeedTried, !upgradeSeedRunning else { return }
        let known = goodStarts().records
        let names = profiles.filter { $0.isRunning && known[$0.name] == nil }.map(\.name)
        guard !names.isEmpty else { return }
        upgradeSeedRunning = true
        Task {
            let now = await probeVersions()
            upgradeSeedRunning = false
            guard UpgradeGuard.canSave(now) else { return }
            let all = goodStarts()
            let seeded = all.seeded(names, with: now)
            if seeded != all { Defaults.set(seeded.json, .goodStartVersions) }
            upgradeSeedTried = true
        }
    }

    /// Removes the records of profiles that `colima list` no longer shows. A
    /// profile with a busy marker stays: a disk shrink deletes it for a short time.
    func pruneGoodStarts(keeping listed: Set<String>) {
        guard !isDebug, !listed.isEmpty else { return }
        let all = goodStarts()
        let busy = Set(all.records.keys.filter { busyMarker(of: $0) != nil })
        let pruned = all.pruned(keeping: listed, busy: busy)
        if pruned != all { Defaults.set(pruned.json, .goodStartVersions) }
    }

    /// After a good wake that ColimaBar started: if the change since the last
    /// good start is risky, tells the user once. The click opens the release
    /// notes. Then the versions become the new record, so the next wake is quiet.
    func recordGoodWake(_ p: String, versions: ToolVersions) {
        guard !isDebug else { return }
        let notice = UpgradeGuard.autoStartNotice(profile: p, last: goodStart(for: p), now: versions)
        saveGoodStart(versions, p)
        if let notice { Notifier.shared.post(notice.text, url: notice.url) }
    }
}
