import AppKit

/// Reports when the Mac goes to sleep and when it comes back. It is the only
/// place that subscribes to power events.
/// A dark wake (Power Nap) sends no `didWakeNotification`.
@MainActor
final class SystemPowerObserver {
    /// The Mac is about to sleep.
    var onSleep: (() -> Void)?
    /// The Mac woke from sleep.
    var onSleepEnd: (() -> Void)?

    private let center: NotificationCenter
    private var tokens: [any NSObjectProtocol] = []

    init(center: NotificationCenter = NSWorkspace.shared.notificationCenter) {
        self.center = center
        tokens.append(
            center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.onSleep?() }
            })
        tokens.append(
            center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.onSleepEnd?() }
            })
    }

    /// Stops the callbacks.
    func stop() {
        for token in tokens { center.removeObserver(token) }
        tokens = []
    }
}
