import Foundation

/// The auto-stop rules for one profile. The same rules apply to the
/// selected profile and to each other running profile. Each profile has its
/// own idle time; the timeout setting is the same for all.
///
/// The idle time uses `SuspendingClock`. It stops while the Mac sleeps, as the
/// VM does, so the time of a system sleep never counts as idle time.
enum AutoStopRule {
    /// The result of one check.
    struct Check: Equatable {
        /// When the idle time started, or nil if the profile is not idle.
        var idleSince: SuspendingClock.Instant?
        /// The idle time is over: confirm and stop the VM.
        var isDue: Bool
    }

    /// A profile is idle when auto-stop is on, its VM runs, no VM action
    /// runs, no container runs and its proxies have no active transfers.
    /// `runningContainers` is nil when the list is unknown, for example
    /// after a failed request: then the profile does not count as idle.
    static func evaluate(
        enabled: Bool, isRunning: Bool, isBusy: Bool, runningContainers: Int?, transfers: Int,
        idleSince: SuspendingClock.Instant?, now: SuspendingClock.Instant, idleMinutes: Int
    ) -> Check {
        guard enabled, isRunning, !isBusy, runningContainers == 0, transfers == 0 else {
            return Check(idleSince: nil, isDue: false)
        }
        guard let since = idleSince else { return Check(idleSince: now, isDue: false) }
        return Check(idleSince: since, isDue: now - since >= .seconds(idleMinutes * 60))
    }

    /// True if the idle time has run for `minutes` now. A check that waits for
    /// a fresh container list calls it again: the limit can change meanwhile.
    static func stillDue(idleSince: SuspendingClock.Instant?, now: SuspendingClock.Instant, minutes: Int) -> Bool {
        guard let since = idleSince else { return false }
        return now - since >= .seconds(minutes * 60)
    }

    /// The wall clock time when the VM stops. The time that is left comes from
    /// the instants, so it grows by the time of a system sleep.
    static func stopTime(
        idleSince: SuspendingClock.Instant, now: SuspendingClock.Instant, wallNow: Date, idleMinutes: Int
    ) -> Date {
        let left = Duration.seconds(idleMinutes * 60) - (now - idleSince)
        return wallNow.addingTimeInterval(left.seconds)
    }

    /// True if the stop time changed enough to publish it: by 1 second or
    /// more, or it appeared or went away.
    static func stopTimeMoved(old: Date?, new: Date?) -> Bool {
        switch (old, new) {
        case (nil, nil): return false
        case let (old?, new?): return abs(new.timeIntervalSince(old)) >= 1
        default: return true
        }
    }

    /// On battery, an idle VM stops after this many minutes at most. It is
    /// about the energy of one restart: a longer idle time costs more.
    static let batteryMinutes = 10
    /// In Low Power Mode, an idle VM stops after this many minutes at most.
    /// It is the shortest preset. It is never "at once", because scripts have
    /// short gaps, for example `compose down && up`.
    static let lowPowerMinutes = 5

    /// Why the idle time is shorter than the user's time.
    enum Reason: Equatable {
        case battery, lowPowerMode

        /// The text for the System tab.
        var note: String {
            switch self {
            case .battery: "on battery"
            case .lowPowerMode: "Low Power Mode"
            }
        }
    }

    /// The idle time that applies now.
    struct Limit: Equatable {
        var minutes: Int
        /// Set only when the power state made the time shorter.
        var reason: Reason?
    }

    /// The idle time for the power state. A shorter time that the user selects
    /// stays. The thermal state does not change it.
    static func limit(minutes: Int, power: PowerState, stopSooner: Bool) -> Limit {
        guard stopSooner else { return Limit(minutes: minutes, reason: nil) }
        let cap: (minutes: Int, reason: Reason)
        if power.lowPowerMode {
            cap = (lowPowerMinutes, .lowPowerMode)
        } else if power.onBattery {
            cap = (batteryMinutes, .battery)
        } else {
            return Limit(minutes: minutes, reason: nil)
        }
        return cap.minutes < minutes
            ? Limit(minutes: cap.minutes, reason: cap.reason) : Limit(minutes: minutes, reason: nil)
    }

    /// The running profiles other than the selected one that auto-stop
    /// checks: only the docker runtime has a container list to check.
    static func otherProfiles(_ profiles: [ProfileRow], selected: String) -> [String] {
        profiles.filter {
            $0.isRunning && $0.name != selected && ColimaModel.hasDockerSocket(runtime: $0.runtime)
                && ProfileName.isValid($0.name)
        }
        .map(\.name)
    }

    /// The pause between two container list requests to another profile.
    /// Work through the profile's proxy resets its idle time at each tick.
    static let otherCheckInterval: TimeInterval = 30

    static func isCheckDue(lastCheck: Date?, now: Date) -> Bool {
        guard let lastCheck else { return true }
        return now.timeIntervalSince(lastCheck) >= otherCheckInterval
    }
}

extension Duration {
    /// The length in seconds, with the fraction.
    fileprivate var seconds: TimeInterval {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
