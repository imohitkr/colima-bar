import AppKit
import Foundation
import Observation
import os

/// Checks GitHub for a newer release once a day (and on demand). A new
/// version is announced once with a notification, and stays visible as a
/// badge in the dashboard footer until the user updates.
@MainActor @Observable
final class Updater {
    static let shared = Updater()
    static let releasesAPI = URL(string: "https://api.github.com/repos/imohitkr/colima-bar/releases/latest")!

    struct Release: Equatable {
        let version: String  // without the leading "v"
        let url: URL
    }

    /// The newest release when it is newer than this build, else nil.
    private(set) var available: Release?
    var enabled = Defaults.bool(.checkUpdates) ?? true {
        didSet {
            Defaults.set(enabled, .checkUpdates)
            if enabled { Task { await check(manual: false) } } else { available = nil }
        }
    }

    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private let log = Logger(category: "update")

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
        let current = AppDelegate.version
        let release = await fetchLatest()
        // The user may have turned checks off while this one ran.
        guard manual || enabled else { return }
        guard let release else {
            if manual { Self.alert("Couldn't check for updates", "GitHub didn't answer. Try again later.") }
            return
        }
        guard Version.parts(current) != nil else {
            if manual {
                Self.alert(
                    "Development build",
                    "This build (\(current)) can't be compared with releases. The latest release is \(release.version)."
                )
            }
            return
        }
        guard Version.isNewer(release.version, than: current) else {
            available = nil
            if manual { Self.alert("You're up to date", "ColimaBar \(current) is the latest version.") }
            return
        }
        available = release
        if manual {
            if Self.alert(
                "ColimaBar \(release.version) is available",
                "You have \(current). Open the release page to download it?",
                buttons: ["Open Release Page", "Later"])
            {
                openReleasePage()
            }
            Defaults.set(release.version, .notifiedVersion)
            return
        }
        // Announce each version once; the footer button stays until updated.
        if Defaults.string(.notifiedVersion) != release.version {
            Defaults.set(release.version, .notifiedVersion)
            Notifier.shared.post(
                "ColimaBar \(release.version) is available (you have \(current)). Click to open the release page.",
                title: "Update available", record: false, url: release.url)
        }
    }

    /// A modal answer for "Check for Updates…", which must always show a
    /// result even when notifications are off. True if the first button won.
    @discardableResult
    private static func alert(_ title: String, _ text: String, buttons: [String] = ["OK"]) -> Bool {
        NSApp.activate()
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        for button in buttons { a.addButton(withTitle: button) }
        return a.runModal() == .alertFirstButtonReturn
    }

    func openReleasePage() {
        NSWorkspace.shared.open(ReleaseLink.page(available?.url))
    }

    private func fetchLatest() async -> Release? {
        var req = URLRequest(url: Self.releasesAPI, timeoutInterval: 15)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("ColimaBar/\(AppDelegate.version)", forHTTPHeaderField: "User-Agent")
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200,
                let j = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                let tag = j["tag_name"] as? String
            else { return nil }
            // html_url is not used: the page URL is built from the checked tag.
            return Release(version: Version.strip(tag), url: ReleaseLink.page(tag: tag))
        } catch {
            log.notice("update check failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
