import Foundation

/// The rules of Doctor: inputs in, results out, no I/O.
enum DoctorRules {
    /// The Homebrew folder of CLI plugins. Docker does not search it unless
    /// `cliPluginsExtraDirs` names it.
    static let homebrewPluginFolder = "/opt/homebrew/lib/docker/cli-plugins"

    static func evaluate(_ i: DoctorInputs) -> [DoctorResult] {
        [
            tools(i), upgrade(i), context(i), appRoutes(i), shellHost(i), credentials(i), plugins(i), vmStatus(i),
            staleFiles(i),
            diskSpace(i),
        ]
    }

    /// The hint on the stopped screen, or nil. `status` is the raw status of
    /// the profile in `colima list`.
    static func stoppedHint(status: String?, startFailed: Bool) -> String? {
        if status == "Broken" { return "Colima reports this profile as Broken." }
        if startFailed { return "The last start of this profile failed." }
        return nil
    }

    static func tools(_ i: DoctorInputs) -> DoctorResult {
        let t = i.tools
        var missing: [String] = []
        if t.colimaPath == nil { missing.append("colima") }
        if t.limactlPath == nil { missing.append("limactl") }
        if !missing.isEmpty {
            return DoctorResult(
                .tools, .problem, "\(missing.joined(separator: " and ")) not found. Install it: brew install colima.")
        }
        if t.dockerPath == nil {
            return DoctorResult(.tools, .warning, "The docker CLI is missing. Install it: brew install docker.")
        }
        let v = t.versions
        let dead = [("colima", v.colima), ("limactl", v.lima), ("docker", v.docker)].filter { $0.1 == nil }.map(\.0)
        if !dead.isEmpty {
            return DoctorResult(
                .tools, .warning,
                "\(dead.joined(separator: " and ")) did not run. Run \(dead[0]) --version in a terminal.")
        }
        let list = [("colima", v.colima), ("lima", v.lima), ("docker", v.docker)]
            .map { "\($0.0) \($0.1 ?? "?")" }.joined(separator: ", ")
        if v.limaIsOld {
            return DoctorResult(
                .tools, .warning, "\(list). Lima before 2.1 does not fix the VM clock after a sleep. Update Colima.")
        }
        return DoctorResult(.tools, .ok, list)
    }

    /// Compares the versions with the ones at the last good start. No fix: the
    /// user backs up and reads the release notes.
    static func upgrade(_ i: DoctorInputs) -> DoctorResult {
        guard let last = i.lastGoodVersions else {
            return DoctorResult(.upgrade, .skipped, "No good start of this profile is recorded yet.")
        }
        guard UpgradeGuard.canSave(last) else {
            return DoctorResult(.upgrade, .skipped, "The record of the last good start is incomplete.")
        }
        let now = i.tools.versions
        guard UpgradeGuard.canSave(now) else { return DoctorResult(.upgrade, .skipped, "See Tools.") }
        let all = now.changed(from: last)
        let risky = UpgradeGuard.riskyChanges(last: last, now: now)
        if !risky.isEmpty {
            return DoctorResult(
                .upgrade, .warning,
                "\(UpgradeGuard.list(all)) since the last good start. Back up important volumes and read the release notes before the next start."
            )
        }
        if all.isEmpty {
            return DoctorResult(.upgrade, .ok, "The same versions as at the last good start.")
        }
        return DoctorResult(.upgrade, .ok, "\(UpgradeGuard.list(all)) since the last good start.")
    }

    static func appRoutes(_ i: DoctorInputs) -> DoctorResult {
        guard i.autoStart else { return DoctorResult(.appRoutes, .skipped, "Auto-start is off.") }
        func foreign(_ host: String?) -> Bool {
            Routing.isForeignHost(host, stableHost: i.stableHost, home: i.home)
        }
        let launchd = i.routes.launchdHost, tc = i.routes.testcontainersHost
        if launchd == i.stableHost, tc == i.stableHost {
            return DoctorResult(.appRoutes, .ok, "Apps and testcontainers use the ColimaBar socket.")
        }
        var notes: [String] = []
        var missing = false
        if foreign(launchd) {
            notes.append("launchd DOCKER_HOST points to another daemon (\(launchd)). ColimaBar leaves it.")
        } else if launchd != i.stableHost {
            notes.append("launchd DOCKER_HOST is not set. IDE test runners miss auto-start.")
            missing = true
        }
        if foreign(tc) {
            notes.append("testcontainers docker.host points to another daemon. ColimaBar leaves it.")
        } else if tc != i.stableHost {
            notes.append("testcontainers docker.host is not set.")
            missing = true
        }
        // Set routes changes the routes only when the docker context is ColimaBar's
        // or can move to it. With the context of a user, it would do nothing.
        if missing, !contextAllowsRoutes(i) {
            notes.append("The docker context is not a ColimaBar context, so ColimaBar leaves the routes.")
            missing = false
        }
        return DoctorResult(.appRoutes, .warning, notes.joined(separator: " "), fix: missing ? .setRoutes : nil)
    }

    /// True if `Routing.apply` sets the routes: the context is ColimaBar's,
    /// the default one, a Colima one, or one that does not exist.
    private static func contextAllowsRoutes(_ i: DoctorInputs) -> Bool {
        guard let cur = i.context.current else { return false }
        if cur.isEmpty || cur == "default" || Routing.isOurs(cur) || Routing.colimaProfile(cur) != nil { return true }
        return i.context.existing.map { !$0.contains(cur) } ?? false
    }

    static func vmStatus(_ i: DoctorInputs) -> DoctorResult {
        if i.vm.listFailed {
            return DoctorResult(
                .vmStatus, .warning, "colima list failed or timed out. The status of the profile is not known.")
        }
        let others = i.vm.others.filter { $0.status == "Broken" && $0.name != i.profile }.map(\.name)
        let otherNote = others.isEmpty ? "" : " Other broken profiles: \(others.joined(separator: ", "))."
        guard let row = i.vm.selected else {
            return DoctorResult(
                .vmStatus, .ok, "The profile has no VM yet. It is created at the first start.\(otherNote)")
        }
        switch row.status {
        case "Broken":
            return DoctorResult(
                .vmStatus, .problem,
                "Colima reports the profile as Broken. Repair removes stale Lima files and starts it.\(otherNote)",
                fix: .repair)
        case "Running", "Stopped":
            return DoctorResult(.vmStatus, others.isEmpty ? .ok : .warning, "\(row.status).\(otherNote)")
        default:
            return DoctorResult(.vmStatus, .warning, "Colima reports the status \(row.status).\(otherNote)")
        }
    }

    static func staleFiles(_ i: DoctorInputs) -> DoctorResult {
        if let code = i.staleListFailure {
            return DoctorResult(.staleFiles, .skipped, "Could not list the pid files (exit \(code)).")
        }
        let bad = i.staleFiles.filter { $0.reason != .gone }
        func names(_ files: [StaleLimaFile]) -> String {
            let shown = files.prefix(3).map { tilde($0.path, i.home) }
            return shown.joined(separator: ", ") + (files.count > 3 ? " and \(files.count - 3) more" : "")
        }
        if !bad.isEmpty {
            let reused = bad.filter { $0.reason == .reused }
            let text =
                reused.isEmpty
                ? "A pid file has no PID: \(names(bad)). Repair removes it."
                : "A pid file names another process: \(names(bad)). Repair removes it first."
            return DoctorResult(.staleFiles, .problem, text, fix: .repair)
        }
        if i.staleUnparsed > 0 {
            return DoctorResult(
                .staleFiles, .warning, "ColimaBar could not read \(i.staleUnparsed) line(s) of the pid file list.")
        }
        if !i.staleFiles.isEmpty {
            return DoctorResult(
                .staleFiles, .ok,
                "Left-over pid files (\(names(i.staleFiles))). Colima and Lima remove them at the next start.")
        }
        return DoctorResult(.staleFiles, .ok, "No stale pid files.")
    }

    static func diskSpace(_ i: DoctorInputs) -> DoctorResult {
        var parts: [(DoctorResult.Status, String)] = []
        if let u = i.disk.vm {
            let r = DiskSpace.vm(u)
            parts.append((r.status, r.text))
        }
        if let free = i.disk.macFreeBytes {
            let r = DiskSpace.mac(freeBytes: free)
            parts.append((r.status, r.text))
        }
        if let why = i.disk.vmError { parts.append((.warning, "VM disk space unknown: \(why)")) }
        guard !parts.isEmpty else { return DoctorResult(.diskSpace, .skipped, "No disk data.") }
        let worst = parts.map(\.0).max() ?? .ok
        var text = parts.map(\.1).joined(separator: "; ") + "."
        if i.disk.vm == nil, i.disk.vmError == nil { text += " The VM is stopped, so its disk is not checked." }
        if worst >= .warning, i.disk.vm.map({ DiskSpace.vm($0).status >= .warning }) == true {
            text += " Use the cleanup buttons on the System tab."
        }
        return DoctorResult(.diskSpace, worst, text)
    }

    /// A path with the home folder as `~`.
    static func tilde(_ path: String, _ home: String) -> String {
        guard !home.isEmpty, path == home || path.hasPrefix(home + "/") else { return path }
        return "~" + path.dropFirst(home.count)
    }
}
