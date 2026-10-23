import AppKit
import Foundation
import Observation
import os

/// Checks GitHub for a newer release once a day (and on demand). A new
/// version is announced once with a notification, and stays visible as a
/// button in the dashboard footer until the user updates. How it updates
/// depends on how ColimaBar was installed (see `InstallSource`, and
/// `Updater+Install` for the in-app install).
@MainActor @Observable
final class Updater {
    static let shared = Updater()
    static var releasesAPI: URL {
        #if COLIMABAR_UPDATE_TEST
            if let base = UpdateTestHooks.base { return base.appendingPathComponent("releases/latest") }
        #endif
        return URL(string: "https://api.github.com/repos/imohitkr/colima-bar/releases/latest")!
    }

    /// What the button for the available release does.
    enum Offer: Equatable {
        /// Download, verify, replace the bundle and restart.
        case install
        /// Show the `brew upgrade` command.
        case homebrew
        /// Open the release page. The text says why ColimaBar cannot install.
        case link(String)
    }

    /// The steps of an in-app install.
    enum Phase: Equatable {
        case idle
        /// A share from 0 to 1.
        case downloading(Double)
        case verifying
        /// Waits for busy work to end. The text names it.
        case waiting(String)
        case installing
    }

    /// The newest release when it is newer than this build, else nil.
    var available: ReleaseInfo?
    /// The note for a newer release that needs a newer macOS than this one.
    /// Such a release is not in `available`: it gets no button and no
    /// notification.
    var macOSNote: String?
    var phase: Phase = .idle
    /// Set after a failed check or swap: this version uses the release page
    /// until the next launch. The text says why.
    var fellBack: String?
    var enabled = Defaults.bool(.checkUpdates) ?? true {
        didSet {
            Defaults.set(enabled, .checkUpdates)
            if enabled {
                Task { await check(manual: false) }
            } else if phase == .idle {
                available = nil
                macOSNote = nil
            }
        }
    }

    /// Set by AppDelegate (like `ColimaModel.dismissPopover`): what the app
    /// does now, and the restart into the new bundle. `relaunch` returns
    /// false if no restart began.
    @ObservationIgnored var activity: @MainActor () -> UpdatePolicy.Activity = { UpdatePolicy.Activity() }
    @ObservationIgnored var relaunch: @MainActor () -> Bool = { false }

    /// Where the work folder of an install is. Tests use another folder.
    @ObservationIgnored var updateDir = Paths.updateDir
    /// Shows a notification (and the alert list) about an install. Tests
    /// replace it.
    @ObservationIgnored var announce: @MainActor (_ body: String, _ title: String, _ url: URL?) -> Void = {
        Notifier.shared.post($0, title: $1, record: true, url: $2)
    }

    @ObservationIgnored let source = InstallSource.detect(
        bundlePath: Bundle.main.bundlePath, version: AppDelegate.version, isDebug: AppDelegate.isDebugRun,
        disk: .live)
    /// The version that an install put in place while this copy still runs
    /// (the restart did not begin or failed). The check does not offer it again.
    @ObservationIgnored var restartPending: String?
    /// Why the last fetch gave no release, for the text of a manual check.
    @ObservationIgnored private var checkProblem: String?
    @ObservationIgnored var installTask: Task<Void, Never>?
    @ObservationIgnored var download: UpdateDownload?
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored let log = Logger(category: "update")

    /// The button for `available`.
    var offer: Offer {
        UpdatePolicy.offer(source: source, hasZip: available?.zip != nil, fellBack: fellBack)
    }

    func start() {
        loop?.cancel()
        loop = Task {
            try? await Task.sleep(for: .seconds(30))  // don't compete with launch work
            while !Task.isCancelled {
                if enabled { await check(manual: false) }
                try? await Task.sleep(for: .seconds(24 * 60 * 60))
            }
        }
    }

    /// `manual`: from "Check for Updates…", which always reports a result.
    func check(manual: Bool) async {
        // An install runs: do not change `available` under it.
        guard phase == .idle else {
            if manual { UpdateAlert.updateInProgress() }
            return
        }
        let current = AppDelegate.version
        let release = await fetchLatest()
        // The user may have turned checks off while this one ran.
        guard manual || enabled else { return }
        guard phase == .idle else { return }
        guard let release else {
            if manual {
                UpdateAlert.info(
                    "Couldn't check for updates", checkProblem ?? UpdatePolicy.checkProblem(status: nil))
            }
            return
        }
        if release.version == restartPending {
            available = nil
            if manual {
                UpdateAlert.info("ColimaBar \(release.version) is installed", "Quit ColimaBar and open it again.")
            }
            return
        }
        switch UpdatePolicy.decision(running: current, latest: release.version) {
        case .devBuild:
            if manual {
                UpdateAlert.info(
                    "Development build",
                    "This build (\(current)) can't be compared with releases. The latest release is \(release.version)."
                )
            }
            return
        case .upToDate:
            available = nil
            macOSNote = nil
            if manual { UpdateAlert.info("You're up to date", "ColimaBar \(current) is the latest version.") }
            return
        case .newer:
            break
        }
        if let note = UpdatePolicy.macOSNote(release) {
            available = nil
            macOSNote = note
            if manual { UpdateAlert.info(note, "This Mac cannot run it, so ColimaBar does not offer it.") }
            return
        }
        macOSNote = nil
        available = release
        if manual {
            Defaults.set(release.version, .notifiedVersion)
            await startUpdate()
            return
        }
        // Announce each version once; the footer button stays until updated.
        if Defaults.string(.notifiedVersion) != release.version {
            Defaults.set(release.version, .notifiedVersion)
            Notifier.shared.post(
                "ColimaBar \(release.version) is available (you have \(current)). Click to open the release page.",
                title: "Update available", record: false, url: release.page)
        }
    }

    func openReleasePage() {
        NSWorkspace.shared.open(ReleaseLink.page(available?.page))
    }

    private func fetchLatest() async -> ReleaseInfo? {
        var req = URLRequest(url: Self.releasesAPI, timeoutInterval: 15)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("ColimaBar/\(AppDelegate.version)", forHTTPHeaderField: "User-Agent")
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let status = (resp as? HTTPURLResponse)?.statusCode
            guard status == 200 else {
                log.notice("update check: GitHub answered with status \(status ?? 0)")
                checkProblem = UpdatePolicy.checkProblem(status: status)
                return nil
            }
            checkProblem = nil
            return ReleaseInfo.parse(data)
        } catch {
            log.notice("update check failed: \(error.localizedDescription, privacy: .public)")
            checkProblem = nil
            return nil
        }
    }
}
