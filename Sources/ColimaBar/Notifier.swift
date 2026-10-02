import AppKit
import os
import UserNotifications

/// Native notifications (ColimaBar's own name and icon). Container alerts get
/// "View logs" and "Restart" buttons. Permission is requested the first time
/// something is worth notifying about. Every alert is also handed to
/// `onAlert`, so the dashboard can list it even when notifications are off.
/// There's deliberately no osascript fallback: clicking one of those banners
/// opens Script Editor.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()

    private let log = Logger(subsystem: "com.imohitkr.ColimaBar", category: "notify")
    private let center = UNUserNotificationCenter.current()
    private static let containerCategory = "CONTAINER"
    private static let viewLogs = "VIEW_LOGS"
    private static let restart = "RESTART"

    /// Called with (action, containerID, containerName) when a button is used.
    var onContainerAction: ((String, String, String) -> Void)?
    /// Called for every alert, delivered or not.
    var onAlert: ((String, String, (id: String, name: String)?) -> Void)?
    /// Called with whether macOS currently allows ColimaBar's notifications.
    var onPermission: ((Bool) -> Void)?

    /// Must run before the app finishes launching so a click that launches
    /// the app isn't lost.
    func install() {
        center.delegate = self
        let logs = UNNotificationAction(identifier: Self.viewLogs, title: "View logs", options: [.foreground])
        let restart = UNNotificationAction(identifier: Self.restart, title: "Restart", options: [])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.containerCategory, actions: [logs, restart],
                                   intentIdentifiers: [], options: []),
        ])
    }

    func post(_ body: String, title: String = "Colima", container: (id: String, name: String)? = nil) {
        onAlert?(title, body, container)
        Task {
            guard await authorized() else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = container == nil ? nil : .default
            if let container {
                content.categoryIdentifier = Self.containerCategory
                content.userInfo = ["id": container.id, "name": container.name]
                content.threadIdentifier = container.name
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

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
        done([.banner, .sound, .list])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler done: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        let action = response.actionIdentifier
        let id = info["id"] as? String ?? ""
        let name = info["name"] as? String ?? ""
        Task { @MainActor in
            if !id.isEmpty {
                // Clicking the banner itself also opens the logs.
                let a = action == UNNotificationDefaultActionIdentifier ? Self.viewLogs : action
                self.onContainerAction?(a, id, name)
            }
            done()
        }
    }

    static func isViewLogs(_ a: String) -> Bool { a == viewLogs }
    static func isRestart(_ a: String) -> Bool { a == restart }
}
