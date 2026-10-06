import AppKit
import UserNotifications
import os

/// The container an alert is about.
struct ContainerRef: Equatable, Sendable {
    let id: String
    let name: String
}

/// A button on a container alert. The raw value is the action identifier
/// that macOS sends back.
enum NotificationAction: String, Sendable {
    case viewLogs = "VIEW_LOGS"
    case restart = "RESTART"

    /// Clicking the banner itself (or any other identifier) opens the logs.
    init(identifier: String) {
        self = identifier == Self.restart.rawValue ? .restart : .viewLogs
    }
}

/// Native notifications (ColimaBar's own name and icon). Container alerts get
/// "View logs" and "Restart" buttons. Permission is requested the first time
/// something is worth notifying about. Every alert is also handed to
/// `onAlert`, so the dashboard can list it even when notifications are off.
/// There's deliberately no osascript fallback: clicking one of those banners
/// opens Script Editor.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()

    private let log = Logger(category: "notify")
    private let center = UNUserNotificationCenter.current()
    private static let containerCategory = "CONTAINER"

    /// Called with (action, container, profile) when a button is used.
    var onContainerAction: ((NotificationAction, ContainerRef, String?) -> Void)?
    /// Called with (title, body, container) for every alert, delivered or not.
    var onAlert: ((String, String, ContainerRef?) -> Void)?
    /// Called with whether macOS currently allows ColimaBar's notifications.
    var onPermission: ((Bool) -> Void)?

    /// A crash-looping container dies about once a minute. This limits the
    /// banners for one container and alert kind to one per 10 minutes.
    private var throttle = AlertThrottle(window: 10 * 60)

    /// Must run before the app finishes launching so a click that launches
    /// the app isn't lost.
    func install() {
        center.delegate = self
        let logs = UNNotificationAction(
            identifier: NotificationAction.viewLogs.rawValue, title: "View logs", options: [.foreground])
        let restart = UNNotificationAction(
            identifier: NotificationAction.restart.rawValue, title: "Restart", options: [])
        center.setNotificationCategories([
            UNNotificationCategory(
                identifier: Self.containerCategory, actions: [logs, restart],
                intentIdentifiers: [], options: [])
        ])
    }

    /// `record: false` for messages about the app itself (updates, tips),
    /// which don't belong in the dashboard's list of container alerts.
    /// `url` makes a click on the banner open that page.
    func post(
        _ body: String, title: String = "Colima", container: ContainerRef? = nil,
        profile: String? = nil, record: Bool = true, url: URL? = nil
    ) {
        if record { onAlert?(title, body, container) }
        // The dashboard list above still gets every alert. Only the banner is skipped.
        if let container, !throttle.allow(AlertThrottle.key(container: container.id, body: body)) { return }
        Task {
            guard await authorized() else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = container == nil ? nil : .default
            if let container {
                content.categoryIdentifier = Self.containerCategory
                content.userInfo = ["id": container.id, "name": container.name, "profile": profile ?? ""]
                content.threadIdentifier = container.name
            } else if let url {
                content.userInfo = ["url": url.absoluteString]
            }
            let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
            do { try await center.add(req) } catch {
                log.error("notification failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Debug: prints the permission state and posts a test alert.
    func selfTest() async {
        let before = await center.notificationSettings().authorizationStatus
        let ok = await authorized()
        let after = await center.notificationSettings().authorizationStatus
        print("notification auth before=\(before.rawValue) after=\(after.rawValue) granted=\(ok)")
        if ok {
            let c = UNMutableNotificationContent()
            c.title = "ColimaBar"
            c.body = "Test notification"
            do {
                try await center.add(UNNotificationRequest(identifier: "selftest", content: c, trigger: nil))
                print("posted")
            } catch { print("post failed: \(error)") }
        }
    }

    private func authorized() async -> Bool {
        let settings = await center.notificationSettings()
        defer { Task { await refreshPermission() } }
        switch settings.authorizationStatus {
        case .authorized, .provisional: return true
        case .notDetermined:
            do {
                return try await center.requestAuthorization(options: [.alert, .sound])
            } catch {
                log.error("notification authorization failed: \(error.localizedDescription, privacy: .public)")
                return false
            }
        default:
            log.notice("notifications not allowed (status \(settings.authorizationStatus.rawValue))")
            return false
        }
    }

    /// Re-reads the permission (e.g. after the user changed it in Settings).
    func refreshPermission() async {
        let st = await center.notificationSettings().authorizationStatus
        onPermission?(st == .authorized || st == .provisional || st == .notDetermined)
    }

    static func openSettings() {
        let url = "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(AppDelegate.bundleID)"
        if let u = URL(string: url) { NSWorkspace.shared.open(u) }
    }

    // MARK: - UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification,
        withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        done([.banner, .sound, .list])
    }

    // The async form of the delegate method: macOS calls its completion handler
    // when this method returns. The handler is not Sendable, so the Swift 6
    // language mode does not let a main actor closure capture it.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
    ) async {
        let info = response.notification.request.content.userInfo
        let action = response.actionIdentifier
        let id = info["id"] as? String ?? ""
        let name = info["name"] as? String ?? ""
        let profile = (info["profile"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        // Open web pages only, never a file or another app's URL scheme.
        let link = (info["url"] as? String).flatMap(URL.init(string:)).flatMap {
            $0.scheme?.lowercased() == "https" ? $0 : nil
        }
        await MainActor.run {
            if let link { NSWorkspace.shared.open(link) }
            if !id.isEmpty {
                // Clicking the banner itself also opens the logs.
                self.onContainerAction?(
                    NotificationAction(identifier: action), ContainerRef(id: id, name: name), profile)
            }
        }
    }
}
