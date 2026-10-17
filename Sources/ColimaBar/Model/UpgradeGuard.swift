import Foundation

/// The rules of the upgrade guard: when a version change is risky, and the
/// texts for it. No I/O.
enum UpgradeGuard {
    /// The line that the script prints after a good start of the VM.
    static let startedMarker = "COLIMABAR_STARTED"

    /// True when the output of the script has the marker of a good start.
    static func started(in output: String) -> Bool {
        output.split(whereSeparator: \.isNewline).contains { $0 == startedMarker }
    }

    /// The risky changes since the last good start. None if there is no
    /// record, or if the record or the current versions of Colima or Lima are
    /// not known: ColimaBar can neither save nor compare then.
    static func riskyChanges(last: ToolVersions?, now: ToolVersions) -> [VersionChange] {
        guard let last, canSave(last), canSave(now) else { return [] }
        return now.changed(from: last).filter(\.isRisky)
    }

    /// A record needs a known version of Colima and of Lima.
    static func canSave(_ v: ToolVersions) -> Bool {
        [v.colima, v.lima].allSatisfy { $0.flatMap(Version.parts) != nil }
    }

    /// The note and the release-notes pages for the script, or nil if this
    /// action asks no question or the change since the last good start is not risky.
    static func warning(
        action: CtlAction, running: Bool, profile: String, last: ToolVersions?, now: ToolVersions?
    ) -> (note: String, releaseNotes: [URL])? {
        guard let now, action.warnsAfterUpgrade(running: running) else { return nil }
        let risky = riskyChanges(last: last, now: now)
        guard !risky.isEmpty else { return nil }
        return (note(profile: profile, changes: risky), releaseNotes(risky))
    }

    /// The notification after a good auto-start, or nil if the change since
    /// the last good start is not risky. The click opens `url`.
    static func autoStartNotice(profile: String, last: ToolVersions?, now: ToolVersions) -> (text: String, url: URL?)? {
        let risky = riskyChanges(last: last, now: now)
        guard !risky.isEmpty else { return nil }
        return (autoStartText(profile: profile, changes: risky), releaseNotes(risky).first)
    }

    /// The text of the dialog before a start.
    static func note(profile: String, changes: [VersionChange]) -> String {
        let list = changes.map(\.text).joined(separator: " and ")
        return
            "\(list) since the last good start of profile '\(profile)'. A new version can change the VM disk. Back up important volumes first, or read the release notes. Continue?"
    }

    /// The text of the notification after an auto-start.
    static func autoStartText(profile: String, changes: [VersionChange]) -> String {
        let list = changes.map { "\($0.tool.rawValue) \($0.to) (before: \($0.from))" }.joined(separator: " and ")
        return "Auto-start started profile \(profile) with \(list). Click for the release notes."
    }

    /// The pages of the release notes of the changed tools. Each URL is built
    /// from the digits of the version only.
    static func releaseNotes(_ changes: [VersionChange]) -> [URL] {
        changes.compactMap { change in
            let base: String
            switch change.tool {
            case .colima: base = "https://github.com/abiosoft/colima/releases/tag/v"
            case .lima: base = "https://github.com/lima-vm/lima/releases/tag/v"
            case .macOS: return nil
            }
            guard let parts = Version.parts(change.to) else { return nil }
            return URL(string: base + parts.map(String.init).joined(separator: "."))
        }
    }

    /// The changes as text, for Doctor.
    static func list(_ changes: [VersionChange]) -> String { changes.map(\.text).joined(separator: ", ") }
}
