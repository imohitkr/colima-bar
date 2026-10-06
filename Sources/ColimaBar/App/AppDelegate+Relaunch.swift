import Foundation

extension AppDelegate {
    /// CFBundleShortVersionString as it is on disk now. Bundle.main caches
    /// the Info.plist it read at launch.
    nonisolated static func onDiskVersion(of bundle: URL) -> String? {
        let plist = NSDictionary(contentsOf: bundle.appendingPathComponent("Contents/Info.plist"))
        return plist?["CFBundleShortVersionString"] as? String
    }

    /// How a running copy restarts after an update replaced its bundle.
    enum Restart: Equatable {
        case none
        /// Quit with a failed exit, so launchd starts the agent again.
        case agent
        /// Open a new instance with `--replace`, then quit.
        case manual
    }

    /// Any change of the version on disk restarts, a downgrade too.
    nonisolated static func restart(running: String, onDisk: String?, isAgent: Bool) -> Restart {
        guard let onDisk, onDisk != running else { return .none }
        return isAgent ? .agent : .manual
    }

    /// A second copy takes over from the running copy only when it is
    /// installed (not run from a DMG or Downloads) and its version is newer
    /// than the running copy's version on disk.
    nonisolated static func takesOver(mine: String, other: String?, installed: Bool) -> Bool {
        guard installed, let other else { return false }
        return Version.isNewer(mine, than: other)
    }

    /// UserDefaults key: the time (seconds since 1970) when an old copy
    /// restarted into the new version for a reopen. The new copy then
    /// reveals the icon and opens the dashboard.
    nonisolated static let revealKey = "revealOnLaunch"

    /// A reveal request counts for 60 s. An older one is from a restart
    /// that failed or was long ago.
    nonisolated static func revealRequestIsFresh(_ requestedAt: Double?, now: Double) -> Bool {
        guard let requestedAt else { return false }
        let age = now - requestedAt
        return age >= 0 && age < 60
    }

    /// Whether the dashboard window counts in visibleCount. A debug snapshot
    /// window sits off screen, so it always counts while open.
    nonisolated static func windowCounts(visible: Bool, miniaturized: Bool, debug: Bool) -> Bool {
        !miniaturized && (visible || debug)
    }
}
