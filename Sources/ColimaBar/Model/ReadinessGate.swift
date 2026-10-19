import Foundation

/// The wait for "Docker is ready" after a VM start. The app (a proxy wake)
/// and the `colimabar` command use it.
///
/// "The socket accepts connections" is not ready: Lima's ssh tunnel opens
/// it seconds before dockerd, and Colima's provisioning restarts dockerd
/// and containerd a few times. A request in that window fails with
/// "Unavailable: error reading from server: EOF". So the gate waits for
/// several successes in a row on an endpoint that goes through containerd.
enum ReadinessGate {
    /// Docker counts as ready after this many successful probes in a row.
    static let streak = 3
    /// The gate gives up after this time.
    static let timeout: TimeInterval = 60
    /// The pause between two probes.
    static let interval: Duration = .milliseconds(500)

    /// The probe request. `GET /images/json` is served by containerd's image store.
    static let probePath =
        "/images/json?filters=" + DockerAPI.percentEncoded(#"{"reference":["colimabar-readiness-probe"]}"#)

    /// A probe of the Docker socket at `socketPath`: true if the request works.
    static func dockerProbe(socketPath: String) -> @Sendable () async -> Bool {
        let api = DockerAPI(socketPath: socketPath)
        return { await api.get(probePath, timeout: 3)?.ok ?? false }
    }

    /// Calls `probe` until it is true `streak` times in a row (true), or until
    /// `timeout` passes or the task is cancelled (false). A failed probe starts
    /// the count again.
    /// `now` and `sleep` are parameters so a test can use its own clock.
    /// The default clock is `SuspendingClock`: a system sleep during the wait
    /// does not use up the time.
    static func wait(
        probe: () async -> Bool, streak: Int = streak, timeout: TimeInterval = timeout,
        interval: Duration = interval, now: () -> SuspendingClock.Instant = { SuspendingClock.now },
        sleep: (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    ) async -> Bool {
        var good = 0
        let deadline = now() + .seconds(timeout)
        while now() < deadline, !Task.isCancelled {
            good = await probe() ? good + 1 : 0
            if good >= streak { return true }
            await sleep(interval)
        }
        return false
    }
}
