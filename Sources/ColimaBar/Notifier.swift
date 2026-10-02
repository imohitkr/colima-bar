import AppKit
import os
import UserNotifications

/// Native notifications (ColimaBar's own name and icon). Container alerts get
/// "View logs" and "Restart" buttons. Permission is requested the first time
/// something is worth notifying about; if it's denied or unavailable, falls
/// back to an osascript banner.
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
        Task {
            guard await authorized() else {
                fallback(title: title, body: body)
                return
            }
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
                fallback(title: title, body: body)
            }
        }
    }

    private func authorized() async -> Bool {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional: return true
        case .notDetermined:
            return (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        default: return false
        }
    }

    private func fallback(title: String, body: String) {
        let esc = { (s: String) in s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") }
        Task { _ = await Shell.run(["osascript", "-e", "display notification \"\(esc(body))\" with title \"\(esc(title))\""]) }
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
