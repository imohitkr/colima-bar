import Foundation

/// The rules for the docker CLI: context, shell, registry login and plugins.
extension DoctorRules {
    /// Where a `DOCKER_HOST` value points.
    enum HostKind: Equatable, Sendable { case colimaBar, colima, dockerDesktop, other }

    /// Classifies a `DOCKER_HOST` value. `$HOME`, `${HOME}` and a leading `~`
    /// are expanded first.
    static func hostKind(_ value: String, home: String) -> HostKind {
        var v = value.replacingOccurrences(of: "${HOME}", with: home).replacingOccurrences(of: "$HOME", with: home)
        if v.contains("~/") { v = v.replacingOccurrences(of: "~/", with: home + "/") }
        if v.contains("/.cache/colima-bar/") { return .colimaBar }
        if v.contains("docker.raw.sock") || v.contains(".docker/run/docker.sock") || v.contains(".docker/desktop") {
            return .dockerDesktop
        }
        if v.contains("/colima/") || v.contains("/.colima/") { return .colima }
        return .other
    }

    static func context(_ i: DoctorInputs) -> DoctorResult {
        guard i.autoStart else { return DoctorResult(.context, .skipped, "Auto-start is off.") }
        guard let cur = i.context.current else {
            return DoctorResult(.context, .warning, "ColimaBar cannot read the docker config file.")
        }
        guard let existing = i.context.existing else {
            return DoctorResult(.context, .warning, "The docker CLI did not answer. Check that it works in a terminal.")
        }
        if cur.isEmpty || cur == "default" {
            return DoctorResult(
                .context, .warning, "docker uses the default context. The docker CLI skips auto-start.",
                fix: .useColimabar)
        }
        if !existing.contains(cur) {
            return DoctorResult(
                .context, .problem,
                "The docker context \(cur) does not exist. docker fails with \"context not found\".",
                fix: .useColimabar)
        }
        if Routing.isOurs(cur) {
            return DoctorResult(.context, .ok, "docker uses the context \(cur). It starts Colima on demand.")
        }
        if Routing.colimaProfile(cur) != nil {
            return DoctorResult(
                .context, .warning, "docker uses the Colima context \(cur). The docker CLI skips auto-start.",
                fix: .useColimabar)
        }
        return DoctorResult(
            .context, .warning,
            "docker uses the context \(cur). It is not a ColimaBar context, so auto-start does not apply.")
    }

    static func shellHost(_ i: DoctorInputs) -> DoctorResult {
        let r = shellHostFound(i)
        guard !i.shell.unreadable.isEmpty else { return r }
        // A file that ColimaBar could not read may hold the line.
        let names = i.shell.unreadable.map { tilde($0, i.home) }.joined(separator: ", ")
        return DoctorResult(
            r.check, max(r.status, .warning), r.detail + " ColimaBar could not read \(names).", fix: r.fix)
    }

    private static func shellHostFound(_ i: DoctorInputs) -> DoctorResult {
        guard let f = i.shell.found, let value = f.value else {
            return DoctorResult(
                .shellHost, .ok,
                "The \(i.shell.name) startup files do not set DOCKER_HOST. For a full check, run \"echo $DOCKER_HOST\" in a new terminal."
            )
        }
        let at = "\(tilde(f.file, i.home)) line \(f.line)"
        switch hostKind(value, home: i.home) {
        case .colimaBar:
            return DoctorResult(.shellHost, .ok, "\(at) sets DOCKER_HOST to the ColimaBar socket.")
        case .colima:
            return DoctorResult(
                .shellHost, .warning,
                "\(at) sets DOCKER_HOST to the Colima socket. This skips auto-start. Replace the line with the copied line.",
                fix: .copyLine)
        case .dockerDesktop:
            return DoctorResult(
                .shellHost, .problem,
                "\(at) sets DOCKER_HOST to Docker Desktop. New terminals do not reach Colima. Replace the line with the copied line.",
                fix: .copyLine)
        case .other:
            return DoctorResult(
                .shellHost, .warning,
                "\(at) sets DOCKER_HOST to \(value). New terminals use that daemon, not Colima.")
        }
    }

    static func credentials(_ i: DoctorInputs) -> DoctorResult {
        if i.dockerConfigUnreadable {
            return DoctorResult(
                .credentials, .warning, "ColimaBar cannot read the docker config file. Check its owner and mode.")
        }
        guard let config = i.credentials.config else {
            return DoctorResult(
                .credentials, .warning, "The docker config file is not valid JSON. docker may fail to read it.")
        }
        let have = i.credentials.available
        if let store = config.credsStore, !have.contains(store) {
            return DoctorResult(
                .credentials, .problem,
                "credsStore names docker-credential-\(store), which is missing. docker pull and docker build fail.",
                fix: have.contains("osxkeychain") ? .useOsxkeychain : nil)
        }
        let missing = config.credHelpers.filter { !have.contains($0.value) }.keys.sorted()
        if !missing.isEmpty {
            return DoctorResult(
                .credentials, .warning,
                "credHelpers names a missing helper for \(missing.prefix(3).joined(separator: ", ")). docker fails for these registries."
            )
        }
        if let store = config.credsStore {
            return DoctorResult(.credentials, .ok, "Registry logins use docker-credential-\(store).")
        }
        return DoctorResult(.credentials, .ok, "No credential helper is set.")
    }

    static func plugins(_ i: DoctorInputs) -> DoctorResult {
        var broken: [String] = []
        var homebrewOnly: [String] = []
        var missing: [String] = []
        var found = 0
        for search in i.plugins {
            let first = search.entries.first { $0.searchedByDocker && $0.state != .missing }
            switch first?.state {
            case .works: found += 1
            case .broken:
                let path = "\(first?.folder ?? "")/\(search.name)"
                broken.append("Broken link \(tilde(path, i.home)). Remove it: rm \(shellQuoted(path)).")
            default:
                if search.entries.contains(where: { $0.folder == homebrewPluginFolder && $0.state == .works }) {
                    homebrewOnly.append(search.name)
                } else {
                    missing.append(search.name)
                }
            }
        }
        var notes = broken
        if !homebrewOnly.isEmpty {
            notes.append(
                "\(homebrewOnly.joined(separator: " and ")) \(homebrewOnly.count == 1 ? "is" : "are") only in \(homebrewPluginFolder). docker does not search it."
            )
        }
        if !missing.isEmpty {
            notes.append(
                "\(missing.joined(separator: " and ")) not found. Install: brew install \(missing.joined(separator: " "))."
            )
        }
        if notes.isEmpty {
            return DoctorResult(.plugins, .ok, "docker finds \(i.plugins.map(\.name).joined(separator: " and ")).")
        }
        if i.dockerConfigUnreadable { notes.append("ColimaBar cannot read the docker config file.") }
        return DoctorResult(
            .plugins, broken.isEmpty ? .warning : .problem, notes.joined(separator: " "),
            fix: homebrewOnly.isEmpty || i.dockerConfigUnreadable ? nil : .addPluginFolder)
    }

    /// A path in single quotes for a shell. `~` does not expand in quotes, so
    /// the path is absolute.
    static func shellQuoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
