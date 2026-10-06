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
        let version: String   // without the leading "v"
        let url: URL
    }

    /// The newest release when it is newer than this build, else nil.
    private(set) var available: Release?
    var enabled = Defaults.bool("checkUpdates") ?? true {
        didSet {
            Defaults.set(enabled, "checkUpdates")
            if enabled { Task { await check(manual: false) } } else { available = nil }
        }
    }

    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private let log = Logger(subsystem: "com.imohitkr.ColimaBar", category: "update")

    func start() {
        loop?.cancel()
        loop = Task {
            try? await Task.sleep(for: .seconds(30))   // don't compete with launch work
            while !Task.isCancelled {
                if enabled { await check(manual: false) }
                try? await Task.sleep(for: .seconds(24 * 60 * 60))
            }
        }
    }

    /// `manual`: from "Check for Updates…", which always reports a result.
    func check(manual: Bool) async {
        let current = AppDelegate.version
        guard let release = await fetchLatest() else {
            if manual { Notifier.shared.post("Couldn't check for updates. Try again later.") }
            return
        }
        guard Version.isNewer(release.version, than: current) else {
            available = nil
            if manual { Notifier.shared.post("ColimaBar \(current) is the latest version.") }
            return
        }
        available = release
        // Announce each version once; the footer badge stays until updated.
        if manual || Defaults.string("notifiedVersion") != release.version {
            Defaults.set(release.version, "notifiedVersion")
            Notifier.shared.post("ColimaBar \(release.version) is available (you have \(current)). Open the dashboard to download it.",
                                 title: "Update available")
        }
    }

    func openReleasePage() {
        NSWorkspace.shared.open(available?.url ?? URL(string: "https://github.com/imohitkr/colima-bar/releases/latest")!)
    }

    private func fetchLatest() async -> Release? {
        var req = URLRequest(url: Self.releasesAPI, timeoutInterval: 15)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("ColimaBar/\(AppDelegate.version)", forHTTPHeaderField: "User-Agent")
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200,
                  let j = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = j["tag_name"] as? String,
                  let page = (j["html_url"] as? String).flatMap(URL.init(string:)) else { return nil }
            return Release(version: Version.strip(tag), url: page)
        } catch {
            log.notice("update check failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}

/// Dotted numeric versions ("0.3.0"). Build suffixes ("0.2.0-4-gabc-dirty")
/// and a leading "v" are ignored.
enum Version {
    static func strip(_ s: String) -> String { s.hasPrefix("v") ? String(s.dropFirst()) : s }

    static func parts(_ s: String) -> [Int]? {
        let core = strip(s).split(separator: "-").first.map(String.init) ?? ""
        let nums = core.split(separator: ".").map { Int($0) }
        guard !nums.isEmpty, nums.allSatisfy({ $0 != nil }) else { return nil }
        return nums.map { $0! }
    }

    /// True if `a` is a higher version than `b`. Unparseable versions (e.g. a
    /// "dev" build) never count as older, so they don't nag.
    static func isNewer(_ a: String, than b: String) -> Bool {
        guard let x = parts(a), let y = parts(b) else { return false }
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }
}
