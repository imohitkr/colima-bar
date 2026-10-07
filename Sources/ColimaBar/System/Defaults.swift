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
    }

    static func string(_ k: Key) -> String? { UserDefaults.standard.string(forKey: k.rawValue) }
    static func bool(_ k: Key) -> Bool? { UserDefaults.standard.object(forKey: k.rawValue) as? Bool }
    static func int(_ k: Key) -> Int? { UserDefaults.standard.object(forKey: k.rawValue) as? Int }
    static func double(_ k: Key) -> Double? { UserDefaults.standard.object(forKey: k.rawValue) as? Double }
    /// UserDefaults' own bool(forKey:): false when the key is unset.
    static func flag(_ k: Key) -> Bool { UserDefaults.standard.bool(forKey: k.rawValue) }
    static func set(_ v: Any, _ k: Key) { UserDefaults.standard.set(v, forKey: k.rawValue) }
    static func remove(_ k: Key) { UserDefaults.standard.removeObject(forKey: k.rawValue) }
}
