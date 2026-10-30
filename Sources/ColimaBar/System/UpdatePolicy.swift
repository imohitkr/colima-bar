import Foundation

/// The rules of an in-app update. All of them are pure functions.
enum UpdatePolicy {
    /// The largest `ColimaBar.zip` that ColimaBar downloads.
    static let maxZipBytes = 50 * 1024 * 1024
    /// The largest unpacked app that ColimaBar accepts.
    static let maxUnpackedBytes = 100 * 1024 * 1024
    /// How long an update waits for busy work before it gives up.
    static let maxWait: TimeInterval = 120

    /// What ColimaBar does now. An update must not restart it while any of
    /// this runs: a restart closes docker connections and can interrupt a
    /// VM action.
    struct Activity: Equatable, Sendable {
        /// The label of the busy marker or action of each profile that has one.
        var busyLabels: [String] = []
        /// Open docker builds, pulls and pushes through the proxies.
        var transfers = 0
        /// Profiles that an auto-start is starting now.
        var wakes = 0
        var doctorRunning = false
        var savingDiagnostics = false
    }

    /// The reason that an update must wait, or nil if it can go on.
    static func blocker(_ a: Activity) -> String? {
        if let label = a.busyLabels.first {
            // An action without a label from the busy marker has an empty one.
            return label.isEmpty ? "A VM action is running" : "A VM action is running (\(label.lowercased()))"
        }
        if a.wakes > 0 { return "Colima is starting for a docker request" }
        if a.transfers > 0 { return "A docker build, pull or push is running" }
        if a.doctorRunning { return "Doctor is running" }
        if a.savingDiagnostics { return "ColimaBar is saving the diagnostics file" }
        return nil
    }

    enum Decision: Equatable {
        case newer
        case upToDate
        /// The running version is not a dotted number ("dev"), so it cannot be compared.
        case devBuild
    }

    /// Whether `latest` is newer than the `running` version.
    static func decision(running: String, latest: String) -> Decision {
        guard Version.parts(running) != nil else { return .devBuild }
        return Version.isNewer(latest, than: running) ? .newer : .upToDate
    }

    /// How long a Homebrew install waits before it checks again when the
    /// cask does not have the newest release yet.
    static let caskRetryDelay: TimeInterval = 60 * 60

    /// The version that a Homebrew install offers, or nil if `brew upgrade`
    /// has nothing newer than `running` yet. That is the release if the cask
    /// has it, else the version of the cask if it is newer than `running`.
    /// If ColimaBar could not read the cask (nil), it offers the release, as
    /// it did before it read the cask.
    static func homebrewVersion(running: String, release: String, cask: String?) -> String? {
        guard let cask, Version.isNewer(release, than: cask) else { return release }
        return Version.isNewer(cask, than: running) ? cask : nil
    }

    /// The text of a manual check when the cask does not have a newer version.
    static func caskLagText(release: String, cask: String?, checksOn: Bool) -> (title: String, text: String) {
        let next = checksOn ? "ColimaBar checks again in an hour." : "Try again later."
        return (
            "ColimaBar \(release) is not in Homebrew yet",
            "The Homebrew cask has \(cask ?? "an older version"). \(next)"
        )
    }

    /// The short note for a release that needs a newer macOS than `os`, or
    /// nil if the release has no such line or `os` is enough. Such a release
    /// gets no offer and no notification.
    static func macOSNote(
        _ release: ReleaseInfo, os: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion
    ) -> String? {
        guard let text = release.minimumMacOS, let minimum = UpdateVerifier.parseSystemVersion(text),
            !UpdateVerifier.isAtLeast(os, minimum)
        else { return nil }
        let name = minimum.patchVersion > 0 || minimum.minorVersion > 0 ? text : "\(minimum.majorVersion)"
        return "ColimaBar \(release.version) needs macOS \(name)"
    }

    /// True if there is room for the download and the unpacked app, with
    /// the same amount again for a copy to another volume.
    static func hasRoom(free: Int64, zipSize: Int) -> Bool {
        free >= Int64(zipSize) + 2 * Int64(maxUnpackedBytes)
    }

    /// The button for a release. `fellBack` (a failed update to this
    /// version) wins. A copy that updates itself needs a zip that ColimaBar
    /// can verify.
    static func offer(source: InstallSource, hasZip: Bool, fellBack: String?) -> Updater.Offer {
        if let fellBack { return .link(fellBack) }
        switch source {
        case .selfUpdate:
            return hasZip ? .install : .link("this release has no download that ColimaBar can verify")
        case .homebrew: return .homebrew
        case .linkOnly(let reason): return .link(reason.text)
        }
    }

    /// The bundle that an install replaces, or nil if no install may start:
    /// a debug run, a running update, a release page after a failed update,
    /// a copy that cannot update itself, or a release without a zip.
    static func installTarget(
        isDebug: Bool, isIdle: Bool, fellBack: String?, source: InstallSource, hasZip: Bool
    ) -> URL? {
        guard !isDebug, isIdle, fellBack == nil, hasZip, case .selfUpdate(let target) = source else { return nil }
        return target
    }

    /// What a failed install changes: the reason for the release page after
    /// an error that does not pass, and whether to show a notification (a
    /// cancel shows none).
    static func afterFailure(_ error: UpdateError) -> (fellBack: String?, notify: Bool) {
        (error.usesReleasePageAfter ? "the last update to this version failed" : nil, error != .cancelled)
    }

    /// The answer of a manual check when GitHub did not give a release.
    static func checkProblem(status: Int?) -> String {
        switch status {
        case 403, 429: "GitHub refused the request (HTTP \(status ?? 0), probably the rate limit). Try again later."
        case let code?: "GitHub answered with HTTP status \(code). Try again later."
        case nil: "GitHub didn't answer. Try again later."
        }
    }

    /// The notice for an install that worked but could not restart ColimaBar.
    static func restartNotice(version: String) -> String {
        "ColimaBar \(version) is installed. Quit ColimaBar and open it again."
    }

    /// The names of the leftover copies beside the bundle that an update can
    /// leave, without the running bundle (it must never be deleted).
    static func leftovers(bundle: String) -> [String] {
        let parent = (bundle as NSString).deletingLastPathComponent
        return [BundleSwap.stagePath(target: bundle), BundleSwap.sidePath(target: bundle)]
            .filter { $0 != bundle && ($0 as NSString).deletingLastPathComponent == parent }
    }
}
