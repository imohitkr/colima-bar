import AppKit
import Darwin
import IOKit.ps
import notify
import os

/// Reports when the Mac goes to sleep and when it comes back. It also reports
/// when the power state changes: the charger, Low Power Mode or the thermal
/// state. It is the only place that subscribes to power events.
/// A dark wake (Power Nap) sends no `didWakeNotification`.
@MainActor
final class SystemPowerObserver {
    /// The Mac is about to sleep.
    var onSleep: (() -> Void)?
    /// The Mac woke from sleep.
    var onSleepEnd: (() -> Void)?
    /// The power state changed. It does not report the first state: read `power`.
    var onPowerChange: ((PowerState) -> Void)?
    /// The last state that the observer read.
    private(set) var power: PowerState

    private let log = Logger(category: "power")
    private let center: NotificationCenter
    private let processCenter: NotificationCenter
    private let readPower: @MainActor () -> PowerState
    private var tokens: [any NSObjectProtocol] = []
    private var sourceToken: Int32 = NOTIFY_TOKEN_INVALID

    /// `watchesPowerSource: false` skips the system notification of the
    /// charger, for tests.
    init(
        center: NotificationCenter = NSWorkspace.shared.notificationCenter,
        processCenter: NotificationCenter = .default,
        readPower: @escaping @MainActor () -> PowerState = PowerState.read,
        watchesPowerSource: Bool = true
    ) {
        self.center = center
        self.processCenter = processCenter
        self.readPower = readPower
        // Read the thermal state first: the thermal notification needs that.
        power = readPower()
        tokens.append(
            center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.onSleep?() }
            })
        tokens.append(
            center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                // The charger can change during a sleep.
                MainActor.assumeIsolated {
                    self?.recheck()
                    self?.onSleepEnd?()
                }
            })
        for name in [Notification.Name.NSProcessInfoPowerStateDidChange, ProcessInfo.thermalStateDidChangeNotification]
        {
            tokens.append(
                processCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.recheck() }
                })
        }
        if watchesPowerSource {
            // Only a switch between the charger and the battery posts this,
            // not each percent of the charge.
            var token = NOTIFY_TOKEN_INVALID
            let status = notify_register_dispatch(kIOPSNotifyPowerSource, &token, .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.recheck() }
            }
            if status == UInt32(NOTIFY_STATUS_OK) {
                sourceToken = token
            } else {
                log.error(
                    "charger notification failed, status \(status, privacy: .public): ColimaBar sees a charger change only at a wake, a Low Power Mode change or a thermal change"
                )
            }
        }
    }

    /// Reads the state again and reports it if it changed.
    private func recheck() {
        let now = readPower()
        guard now != power else { return }
        power = now
        onPowerChange?(now)
    }

    /// Stops the callbacks.
    func stop() {
        for token in tokens {
            center.removeObserver(token)
            processCenter.removeObserver(token)
        }
        tokens = []
        if sourceToken != NOTIFY_TOKEN_INVALID {
            notify_cancel(sourceToken)
            sourceToken = NOTIFY_TOKEN_INVALID
        }
    }
}
