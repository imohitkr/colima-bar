import Foundation
import ServiceManagement
import os

/// Launch at login through a LaunchAgent with KeepAlive, so a crash relaunches
/// ColimaBar immediately instead of leaving the proxy socket dead. A normal
/// Quit (exit 0) is respected.
///
/// This is a plain plist in ~/Library/LaunchAgents, not SMAppService: launchd
/// pins an SMAppService agent to the code signature it was registered with,
/// and an ad-hoc signed app gets a new signature with every build, so after
/// an update launchd refused to start it (EX_CONFIG, launch constraint
/// violation) and ColimaBar didn't start at login.
@MainActor
enum LoginItem {
    nonisolated static let label = "com.imohitkr.ColimaBar.login"
    /// Label of the SMAppService agent used up to v0.2.0 (see migrate()).
    nonisolated static let legacyLabel = "com.imohitkr.ColimaBar.agent"
    nonisolated static var plistPath: String { "\(Paths.home)/Library/LaunchAgents/\(label).plist" }
    nonisolated private static var domain: String { "gui/\(getuid())" }
    nonisolated private static let log = Logger(category: "login")
    /// Runs launchctl off the main thread, one call after another, so
    /// quick on/off toggles reach launchd in order.
    nonisolated private static let queue = DispatchQueue(label: "com.imohitkr.ColimaBar.login")

    static var isEnabled: Bool { FileManager.default.fileExists(atPath: plistPath) }

    /// True when the agent exists but was turned off in System Settings >
    /// General > Login Items, so launchd won't run it.
    static var needsApproval: Bool { isEnabled && disabledInSettings() }

    /// Runs launchctl: call it off the main thread from UI code.
    nonisolated static func disabledInSettings() -> Bool {
        let out = launchctl(["print-disabled", "gui/\(getuid())"]).out
        return out.contains("\"\(label)\" => disabled") || out.contains("\"\(label)\" => true")
    }

    /// The job is loaded in launchd (running or not). Runs launchctl.
    nonisolated static var isLoaded: Bool { launchctl(["print", "\(domain)/\(label)"]).ok }

    /// On: writes the plist and loads the job, which starts the agent
    /// (RunAtLoad). The agent then takes over from this copy, the same way as
    /// at launch: it quits this copy and waits for it to exit. If launchd
    /// refuses the job, this copy keeps running unsupervised.
    /// The job can still be loaded when the agent turned launch at login off
    /// and then quit. A copy started by hand reloads it, so launchd reads the
    /// new plist and starts the agent. The agent itself only writes the plist:
    /// its job is still loaded and keeps it alive.
    /// Off: removes the plist, so it won't start at the next login. When this
    /// copy *is* the agent, the job stays loaded until logout: unloading it
    /// would kill this process (and the proxy) on the spot.
    /// The plist changes before this returns, so isEnabled (and the UI that
    /// reads it) is correct at once. launchctl runs later on a background
    /// queue: a bootstrap can retry for about 2 s, and the menu or toggle
    /// must not hang meanwhile. bootstrap() logs a failure.
    static func set(_ on: Bool) throws {
        if on {
            try writePlist()
        } else {
            try? FileManager.default.removeItem(atPath: plistPath)
        }
        guard !AppDelegate.isLaunchAgent else { return }
        queue.async {
            if on {
                if isLoaded { launchctl(["bootout", "\(domain)/\(label)"]) }
                bootstrap()
            } else {
                launchctl(["bootout", "\(domain)/\(label)"])
            }
        }
    }

    /// Rewrites the plist if the app moved or the plist is outdated, so it
    /// always starts the installed binary.
    /// Only an installed copy (in /Applications or ~/Applications) takes the
    /// plist over, or any copy when the plist's binary is gone. A copy run
    /// from Downloads or a build folder must not repoint it.
    /// If only other keys differ (an older version wrote the plist), it
    /// rewrites the file but does not reload the job. launchd reads the new
    /// keys at the next login. The agent also calls this: a reload would
    /// kill it.
    static func refreshIfNeeded() {
        guard isEnabled, let exe = Bundle.main.executablePath,
            let data = FileManager.default.contents(atPath: plistPath),
            let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return }
        let current = plist["Program"] as? String ?? ""
        guard current != exe else {
            if plistIsOutdated(plist, exe: exe) {
                log.notice("login agent plist is outdated; rewriting it")
                try? writePlist()
            }
            return
        }
        guard !AppDelegate.isLaunchAgent else { return }
        guard isInstalled(exe) || !FileManager.default.isExecutableFile(atPath: current) else { return }
        log.notice("login agent points at another binary; updating it")
        try? writePlist()
        launchctl(["bootout", "\(domain)/\(label)"])
        bootstrap()
    }

    /// True for a path inside /Applications or ~/Applications that macOS
    /// did not translocate (a copy run from a DMG or Downloads is not).
    nonisolated static func isInstalled(_ path: String) -> Bool {
        (path.hasPrefix("/Applications/") || path.hasPrefix("\(Paths.home)/Applications/"))
            && !path.contains("/AppTranslocation/")
    }

    /// Loads the job. Right after a bootout, launchd can still be removing
    /// the old job and refuse the bootstrap for a moment, so retry briefly.
    @discardableResult
    nonisolated private static func bootstrap() -> Bool {
        var r = launchctl(["bootstrap", domain, plistPath])
        var tries = 0
        while !r.ok, !isLoaded, tries < 10 {
            usleep(200_000)
            r = launchctl(["bootstrap", domain, plistPath])
            tries += 1
        }
        if !r.ok, !isLoaded { log.error("launchctl bootstrap failed: \(r.out, privacy: .public)") }
        return r.ok || isLoaded
    }

    /// Asks launchd to start the agent now, loading it first if needed.
    /// True if launchctl accepted it.
    static func kickstart() -> Bool {
        if launchctl(["kickstart", "\(domain)/\(label)"]).ok { return true }
        return launchctl(["bootstrap", domain, plistPath]).ok
    }

    /// Moves older installs (SMAppService agent or plain login item) to the
    /// plist agent.
    /// The bundle still ships the old agent plist only so SMAppService can
    /// find, and unregister, that registration.
    /// Runs once: if unregistering fails, it must not re-enable launch at
    /// login on every start after the user turned it off.
    static func migrate() {
        guard !Defaults.flag(.didMigrateLoginItem) else { return }
        Defaults.set(true, .didMigrateLoginItem)
        let old = SMAppService.agent(plistName: "\(legacyLabel).plist")
        let hadOld =
            old.status == .enabled || old.status == .requiresApproval
            || SMAppService.mainApp.status == .enabled
        guard hadOld else { return }
        try? old.unregister()
        try? SMAppService.mainApp.unregister()
        log.notice("migrating launch at login to ~/Library/LaunchAgents")
        if !isEnabled { try? set(true) }
    }

    /// The LaunchAgent plist for the binary at `exe`.
    /// SoftResourceLimits raises the open-file limit from launchd's 256
    /// (see FileLimit). The app also raises it itself at launch.
    nonisolated static func plistContents(exe: String) -> [String: Any] {
        [
            "Label": label,
            "Program": exe,
            "RunAtLoad": true,
            "KeepAlive": ["SuccessfulExit": false],
            "ProcessType": "Interactive",
            "LimitLoadToSessionType": "Aqua",
            "SoftResourceLimits": ["NumberOfFiles": Int(FileLimit.wanted)],
        ]
    }

    /// True when the plist on disk differs from the one this version writes.
    nonisolated static func plistIsOutdated(_ plist: [String: Any], exe: String) -> Bool {
        !NSDictionary(dictionary: plist).isEqual(to: plistContents(exe: exe))
    }

    private static func writePlist() throws {
        guard let exe = Bundle.main.executablePath else { throw CocoaError(.fileNoSuchFile) }
        let data = try PropertyListSerialization.data(
            fromPropertyList: plistContents(exe: exe), format: .xml, options: 0)
        try FileManager.default.createDirectory(
            atPath: (plistPath as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true)
        try data.write(to: URL(fileURLWithPath: plistPath), options: .atomic)
    }

    @discardableResult
    nonisolated private static func launchctl(_ args: [String]) -> Shell.Result {
        Shell.runSync("/bin/launchctl", args, includeStderr: true)
    }
}
