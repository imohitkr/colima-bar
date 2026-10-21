import Foundation

/// Typed-ish UserDefaults access that distinguishes "unset" from false/0.
enum Defaults {
    /// Every UserDefaults key the app uses. Do not change a raw value: it
    /// is the stored key, so a new value loses the user's saved setting.
    enum Key: String, CaseIterable {
        case profile
        case notifyOnCrash
        /// Keep the logs of removed containers that fail (`RemovedLogKeeper`).
        case keepRemovedLogs
        case autoStart
        case autoStop
        case autoStopMinutes
        /// Stop sooner on battery or in Low Power Mode (`AutoStopRule.limit`).
        case autoStopSooner
        case hideIconWhenStopped
        case toldIconHidden
        case apiVersion
        case checkUpdates
        case notifiedVersion
        case didOfferLoginItem
        case didMigrateLoginItem
        /// The time (seconds since 1970) when an old copy restarted into the
        /// new version for a reopen. The new copy then reveals the icon and
        /// opens the dashboard.
        case revealOnLaunch
        /// The tool versions at the last good start of each profile, as JSON
        /// (`GoodStarts`). It is machine state, not a setting.
        case goodStartVersions
        /// The version that an in-app update installed. The new copy reads
        /// it once at launch, shows one notification and removes the key.
        case installedVersion
        /// The path of the old bundle after a failed update that could not
        /// put it back. The launch clean-up keeps the update folder and the
        /// hidden copies while this path exists.
        case recoveryPath
        /// Ask before a link starts, stops or restarts a VM. It is not in the
        /// settings file: a file must not turn off a safety question.
        case askBeforeLinks
        /// Links that a copy started by hand gives to the login agent, as
        /// `["at": seconds, "links": [text]]` (`LinkInbox.handoff`). It is
        /// machine state, not a setting.
        case linkHandoff
        /// The keyboard shortcut for the dashboard, as a spec such as
        /// `control+option+command+C` (`KeyCombo.spec`). Unset means none.
        case hotKey
        /// The image of the debug shell (`DebugShell.image`). Set it with
        /// `defaults write`. It is not in the settings file.
        case debugShellImage
        /// Run a weekly cleanup of dangling images and build cache. Off by default.
        case scheduledPrune
        /// The last weekly cleanup of each profile, as profile to seconds
        /// since 1970 (`PruneSchedule`). It is machine state, not a setting.
        case scheduledPruneLastRun
    }

    static func string(_ k: Key) -> String? { UserDefaults.standard.string(forKey: k.rawValue) }
    static func bool(_ k: Key) -> Bool? { UserDefaults.standard.object(forKey: k.rawValue) as? Bool }
    static func int(_ k: Key) -> Int? { UserDefaults.standard.object(forKey: k.rawValue) as? Int }
    static func dictionary(_ k: Key) -> [String: Any]? { UserDefaults.standard.dictionary(forKey: k.rawValue) }
    static func double(_ k: Key) -> Double? { UserDefaults.standard.object(forKey: k.rawValue) as? Double }
    /// UserDefaults' own bool(forKey:): false when the key is unset.
    static func flag(_ k: Key) -> Bool { UserDefaults.standard.bool(forKey: k.rawValue) }
    static func set(_ v: Any, _ k: Key) { UserDefaults.standard.set(v, forKey: k.rawValue) }
    static func remove(_ k: Key) { UserDefaults.standard.removeObject(forKey: k.rawValue) }
}
