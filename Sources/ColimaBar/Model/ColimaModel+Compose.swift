import Foundation

/// The Compose shortcuts of the project menu (`ComposeMenu`). Each one runs
/// `colima-ctl.sh compose-pull|compose-up|compose-down`. The script owns the
/// checks and the confirmation of `down`. It prints the output of
/// `docker compose` on stdout only, so it never reaches ctl.log.
extension ColimaModel {
    /// The most lines of output that ColimaBar keeps for a project.
    nonisolated static let composeOutputLimit = 200

    /// The lines of `docker compose` in the output of the script, the last
    /// `composeOutputLimit` of them. The notice lines are not part of it.
    nonisolated static func composeLines(in output: String) -> [String] {
        let lines = output.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.hasPrefix("COLIMABAR_NOTIFY:") }
            .map(String.init)
        let trimmed = lines.last == "" ? Array(lines.dropLast()) : lines
        return Array(trimmed.suffix(composeOutputLimit))
    }

    /// True if ColimaBar may run `docker compose` now. A debug run changes
    /// nothing, the old copy quits after an update, and a project runs one
    /// action at a time.
    nonisolated static func mayRunCompose(updateRestarting: Bool, isDebug: Bool, projectBusy: Bool) -> Bool {
        !updateRestarting && !isDebug && !projectBusy
    }

    /// The key of a project in `composeBusy`, `composeOutput` and
    /// `composeIssues`. Two profiles can have a project of the same name.
    nonisolated static func composeKey(profile: String, name: String) -> String { "\(profile)/\(name)" }

    func composeKey(_ project: ComposeProject) -> String { Self.composeKey(profile: profile, name: project.name) }

    /// The time limit of one compose action, in seconds.
    nonisolated static let composeTimeout: TimeInterval = 900

    /// True if the process of the script ended because of the time limit: the
    /// script exits with 143 on TERM, and ColimaBar sends KILL after 10 s.
    nonisolated static func composeTimedOut(status: Int32) -> Bool { [9, 15, 143].contains(status) }

    /// The notification for a run that did not work, or nil if the run worked,
    /// the user cancelled the dialog (exit 2) or the script posted a notice.
    nonisolated static func composeFailureNotice(
        verb: ComposeVerb, name: String, status: Int32, scriptNotified: Bool
    ) -> String? {
        if composeTimedOut(status: status) {
            return "Compose \(verb.title) for \(name) timed out after 15 minutes and was stopped."
        }
        guard status != 0, status != 2, !scriptNotified else { return nil }
        return "Compose \(verb.title) failed for \(name) (exit \(status))."
    }

    func compose(_ verb: ComposeVerb, project: ComposeProject) {
        let key = composeKey(project)
        guard
            Self.mayRunCompose(
                updateRestarting: updateRestarting, isDebug: isDebug, projectBusy: composeBusy.contains(key))
        else { return }
        let missing = project.missingFiles { FileManager.default.fileExists(atPath: $0) }
        guard missing.isEmpty else {
            notify("The Compose files of \(project.name) are missing. The project folder moved or was deleted.")
            return
        }
        // The dialog comes from the script, so the popover must not cover it.
        if verb.action.showsDialog(running: true) { dismissPopover() }
        setComposeBusy(composeBusy.union([key]))
        let p = profile
        Task { await runCompose(verb, project: project, profile: p) }
    }

    private func runCompose(_ verb: ComposeVerb, project: ComposeProject, profile p: String) async {
        let action = verb.action
        let key = Self.composeKey(profile: p, name: project.name)
        let env = action.environment(profile: p, expectRunning: nil)
        // Shell.run returns after the script ended. On the time limit the
        // script stops docker compose first, so busy stays on until then.
        let r = await Shell.run(
            [Paths.ctl, action.rawValue] + project.ctlArgs(), timeout: Self.composeTimeout, extraEnv: env)
        let notices = Self.notices(in: r.out)
        for text in notices { notify(text) }
        if let text = Self.composeFailureNotice(
            verb: verb, name: project.name, status: r.status, scriptNotified: !notices.isEmpty)
        {
            notify(text)
        }
        let lines = Self.composeLines(in: r.out)
        if !lines.isEmpty { setComposeOutput(lines, key: key) }
        setComposeBusy(composeBusy.subtracting([key]))
        if p == profile {
            await refreshContainers()
            requestDF(urgent: action.changesDisk)
        }
    }

    /// Checks the files and the docker tool of the Compose projects off the
    /// main thread, so a render never reads the disk. Called after each
    /// container refresh.
    func refreshComposeIssues() async {
        let projects = Array(Set(containers.compactMap { $0.compose?.name }))
            .compactMap { name in containers.first { $0.compose?.name == name }?.compose }
        // No project: no disk read and no lookup of the docker tool.
        guard !projects.isEmpty else {
            setComposeIssues([], hasDocker: true)
            return
        }
        let p = profile
        let (missing, hasDocker) = await Task.detached { () -> (Set<String>, Bool) in
            let gone = projects.filter {
                !$0.missingFiles { FileManager.default.fileExists(atPath: $0) }.isEmpty
                    || !FileManager.default.fileExists(atPath: $0.directory)
            }
            return (Set(gone.map { $0.name }), Shell.which("docker") != nil)
        }.value
        guard p == profile else { return }
        setComposeIssues(Set(missing.map { Self.composeKey(profile: p, name: $0) }), hasDocker: hasDocker)
    }
}
