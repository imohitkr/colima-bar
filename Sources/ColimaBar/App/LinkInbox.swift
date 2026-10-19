import Foundation
import OSLog

/// Holds the links that reach the app and hands them out one at a time.
///
/// The Apple event handler only calls `receive`. The inbox keeps the link
/// until `open` runs, at the end of launch, so a link that launched the app
/// is not lost. The rules against a burst of links:
/// - hold at most 4 links,
/// - drop the same text if it repeats within 2 seconds,
/// - drop every new link while a question is open,
/// - handle one link at a time.
/// A debug run drops every link: it must change nothing.
@MainActor
final class LinkInbox {
    nonisolated static let maxHeld = 4
    nonisolated static let repeatWindow: TimeInterval = 2
    /// A handoff to the login agent counts for 60 seconds.
    nonisolated static let handoffWindow: TimeInterval = 60
    /// The notifications of one link text and kind come at most once per
    /// minute. All link notifications together come at most 5 per minute.
    private static let noticeWindow: TimeInterval = 60
    nonisolated static let maxNotices = 5

    private let acceptsLinks: Bool
    private let clock: () -> Date
    private var held: [String] = []
    private var recent: [String: Date] = [:]
    private var handler: (@MainActor (String) async -> Void)?
    private var draining = false
    private var notices: AlertThrottle
    private var noticeTimes: [Date] = []
    private let log = Logger(category: "links")

    /// A question is open. The handler sets it around the dialog.
    var isAsking = false

    init(acceptsLinks: Bool, clock: @escaping () -> Date = Date.init) {
        self.acceptsLinks = acceptsLinks
        self.clock = clock
        notices = AlertThrottle(window: Self.noticeWindow, clock: clock)
    }

    /// The held links, oldest first. They stay held.
    var pending: [String] { held }

    /// Takes a link text. The inbox drops it if a rule says so.
    func receive(_ text: String) {
        guard acceptsLinks else {
            log.notice("link ignored in a debug run")
            return
        }
        let now = clock()
        recent = recent.filter { now.timeIntervalSince($0.value) < Self.repeatWindow }
        guard !isAsking else {
            log.notice("link dropped: a question is open")
            return
        }
        guard recent[text] == nil else {
            log.notice("link dropped: the same link came again")
            return
        }
        guard held.count < Self.maxHeld else {
            log.notice("link dropped: too many links wait")
            return
        }
        recent[text] = now
        held.append(text)
        drain()
    }

    /// Starts to hand out links, the held ones first, in order.
    func open(_ handler: @escaping @MainActor (String) async -> Void) {
        self.handler = handler
        drain()
    }

    /// Takes all held links out, for a handoff to another copy.
    func takeAll() -> [String] {
        defer { held = [] }
        return held
    }

    /// True if a notification for this link text and kind (the failure or the
    /// refusal) may go out now. The same pair gets one per minute and all
    /// pairs together get 5 per minute, so a loop of bad links, or many
    /// different ones, does not flood the notification center.
    func allowsNotice(for text: String, kind: String) -> Bool {
        let now = clock()
        noticeTimes = noticeTimes.filter { now.timeIntervalSince($0) < Self.noticeWindow }
        guard noticeTimes.count < Self.maxNotices, notices.allow(kind + "|" + text) else { return false }
        noticeTimes.append(now)
        return true
    }

    private func drain() {
        guard let handler, !draining else { return }
        draining = true
        Task { @MainActor in
            while !held.isEmpty {
                await handler(held.removeFirst())
            }
            draining = false
        }
    }

    // MARK: - Handoff to the login agent

    /// The value for `Defaults.Key.linkHandoff`.
    nonisolated static func handoffValue(_ links: [String], now: Double) -> [String: Any] {
        ["at": now, "links": links]
    }

    /// The `at` stamp of a stored handoff, or nil.
    nonisolated static func handoffStamp(_ stored: Any?) -> Double? {
        (stored as? [String: Any])?["at"] as? Double
    }

    /// True if the stored handoff is the one this copy wrote at `stamp`. If it
    /// is gone or has another stamp, the agent took it and handles the links.
    nonisolated static func handoffIsStillMine(_ stored: Any?, stamp: Double) -> Bool {
        handoffStamp(stored) == stamp
    }

    /// The texts that can become URLs, and how many cannot.
    nonisolated static func urls(from texts: [String]) -> (urls: [URL], dropped: Int) {
        let urls = texts.compactMap { URL(string: $0) }
        return (urls, texts.count - urls.count)
    }

    /// The links in a stored handoff, or none. A handoff is fresh for 60
    /// seconds. A value of the wrong type, more than 4 links or a link that
    /// is not text voids all of it. A link over the byte limit is dropped.
    /// The agent parses each link again.
    nonisolated static func handoff(_ stored: Any?, now: Double) -> [String] {
        guard let dict = stored as? [String: Any], let at = dict["at"] as? Double,
            let links = dict["links"] as? [String]
        else { return [] }
        let age = now - at
        guard age >= 0, age < handoffWindow, links.count <= maxHeld else { return [] }
        return links.filter { $0.utf8.count <= AppLink.maxBytes }
    }
}
