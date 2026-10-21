import Foundation

/// One event of a container, as the gate reads it.
struct ContainerAlertInput: Sendable {
    let id: String
    /// "die", "oom", "kill", "start", "destroy" or "health_status: ...".
    let action: String
    let exitCode: String?
    let signal: String?
    let now: Date
}

/// The whole policy for container alerts: what is a crash, what is a loop and
/// what is a normal stop. It is pure: the caller posts the result.
struct ContainerAlertGate: Sendable {
    /// Send "Healthy again" after an unhealthy alert.
    var recoveryEnabled = false

    enum Result: Equatable, Sendable {
        case none
        case post(ContainerAlertOutcome)
        /// The container turned unhealthy in its start grace. Look again later.
        case recheckUnhealthy(after: TimeInterval)
    }

    private var loops = RestartLoopTracker()
    private var quiet = QuietWindows()
    private var alertedUnhealthy: Set<String> = []

    mutating func react(_ input: ContainerAlertInput) -> Result {
        let id = input.id
        let now = input.now
        switch input.action {
        case "kill":
            quiet.noteKill(id: id, signal: input.signal, now: now)
        case "start":
            quiet.noteStart(id: id, now: now)
        case "destroy":
            loops.forget(id: id)
            quiet.forget(id: id)
            alertedUnhealthy.remove(id)
        case "die":
            guard !quiet.stopIsExpected(id: id, now: now) else { return .none }
            switch loops.recordExit(id: id, now: now) {
            case .first, .repeated:
                // An earlier exit with a normal code must not hide a real crash.
                if ColimaModel.isCrashExit(input.exitCode), let code = input.exitCode, !loops.crashAlerted(id: id) {
                    loops.markCrashAlerted(id: id)
                    return .post(.crash(code: code))
                }
            case .loopStarted(let count):
                // A service with `restart: always` that exits with 0 is a loop too.
                return .post(.loop(count: count, lastCode: input.exitCode))
            case .stillLooping:
                break
            }
        case "oom":
            // An OOM kill sends no `kill` event, so a stop window does not apply.
            // The `die` with code 137 that follows counts as an exit.
            // The silence ends 5 minutes after the last exit, not after 10.
            if loops.isLooping(id: id, now: now, within: RestartLoopTracker.window) { return .none }
            // The next exit starts the loop and sends the loop notice: one alert is enough.
            let recent = loops.exitCount(id: id, now: now, within: RestartLoopTracker.window)
            if recent >= RestartLoopTracker.threshold - 1 { return .none }
            return .post(.oom)
        case "health_status: unhealthy":
            if loops.isLooping(id: id, now: now, within: RestartLoopTracker.window) { return .none }
            // dockerd sends this event only on a change: look again after the hold.
            if quiet.isHeld(now: now) { return .recheckUnhealthy(after: quiet.holdLeft(now: now) + 1) }
            let left = quiet.startGraceLeft(id: id, now: now)
            return left > 0 ? .recheckUnhealthy(after: left + 1) : .post(.unhealthy)
        case "health_status: healthy":
            loops.endLoop(id: id)
            if alertedUnhealthy.remove(id) != nil, recoveryEnabled { return .post(.recovered) }
        default:
            break
        }
        return .none
    }

    /// Call it only when the unhealthy banner went out. A muted or throttled
    /// banner is not an alert, so it gets no "Healthy again".
    mutating func markUnhealthyAlerted(_ id: String) {
        alertedUnhealthy.insert(id)
    }

    /// True if the banner of this outcome went out and it was an unhealthy
    /// alert: only that one earns a "Healthy again".
    static func marksUnhealthyAlerted(outcome: ContainerAlertOutcome, sent: Bool) -> Bool {
        sent && outcome == .unhealthy
    }

    /// Whether the unhealthy alert of a deferred check goes out. The VM must
    /// run and the check must still wait (a `destroy` ends it). A fresh list
    /// that shows the container healthy cancels it. A list that is out of
    /// reach does not: the alert goes out unchecked.
    static func shouldPostDeferredUnhealthy(
        vmRunning: Bool, stillWaiting: Bool, listFresh: Bool, stillUnhealthy: Bool
    ) -> Bool {
        guard vmRunning, stillWaiting else { return false }
        return !listFresh || stillUnhealthy
    }

    mutating func holdAll() { quiet.holdAll() }

    mutating func releaseAll(now: Date) { quiet.releaseAll(now: now) }
}
