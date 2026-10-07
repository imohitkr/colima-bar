import Foundation

/// Export and import of the user settings (`SettingsTransfer`).
extension ColimaModel {
    /// The current user settings, for an export or an import plan.
    var settingsSnapshot: SettingsTransfer.Snapshot {
        [
            .autoStart: .bool(autoStart),
            .autoStop: .bool(autoStop),
            .autoStopMinutes: .int(autoStopMinutes),
            .hideIconWhenStopped: .bool(hideIconWhenStopped),
            .notifyOnCrash: .bool(notifyOnCrash),
            .keepRemovedLogs: .bool(keepRemovedLogs),
            .checkUpdates: .bool(Updater.shared.enabled),
            .profile: .string(profile),
            .launchAtLogin: .bool(LoginItem.isEnabled),
        ]
    }

    /// The names of the profiles that `colima list` shows.
    var profileNames: Set<String> { Set(profiles.map(\.name)) }

    /// Applies one change through the normal setters, so their side effects
    /// run: the proxy starts or stops, the login item changes, and a profile
    /// switch clears the old data. Returns a note if the change was skipped.
    func apply(_ change: SettingsTransfer.Change) -> String? {
        let s = change.setting
        switch (s, change.to) {
        case (.autoStart, .bool(let v)): autoStart = v
        case (.autoStop, .bool(let v)): autoStop = v
        case (.autoStopMinutes, .int(let v)): autoStopMinutes = IdleMinutes.clamp(v)
        case (.hideIconWhenStopped, .bool(let v)): hideIconWhenStopped = v
        case (.notifyOnCrash, .bool(let v)): notifyOnCrash = v
        case (.keepRemovedLogs, .bool(let v)): keepRemovedLogs = v
        case (.checkUpdates, .bool(let v)): Updater.shared.enabled = v
        case (.profile, .string(let name)):
            // The profile can be deleted while the confirmation is open.
            guard profileNames.contains(name) else { return "Profile: \(name) does not exist on this Mac." }
            profile = name
        case (.launchAtLogin, .bool(let v)):
            // A debug run must not change the login item.
            guard !AppDelegate.isDebugRun else { return "\(s.title): not changed in a debug run." }
            do {
                try LoginItem.set(v)
            } catch {
                return "\(s.title): \(error.localizedDescription)"
            }
        default:
            return "\(s.title): the value has the wrong type."
        }
        return nil
    }
}
