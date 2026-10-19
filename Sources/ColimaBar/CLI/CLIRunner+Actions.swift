import AppKit
import Foundation

/// The commands that change something: `start`, `stop`, `restart` and `open`.
extension CLIRunner {
    /// The longest wait for another action of the profile.
    static let waitSeconds = 15 * 60

    /// Starts, stops or restarts the VM with `colima-ctl.sh`, as the app does.
    /// The command asks no question. It sets no upgrade note and records no good start.
    static func vmAction(_ action: CtlAction, _ request: CLIRequest, output o: CLIOutput) async -> Int32 {
        let p = CLIProfile.resolve(explicit: request.profile)
        var list = await CLIStatusProbe.list()
        switch list {
        case .notInstalled:
            o.err("Colima is not installed. To install it, run: brew install colima docker")
            return CLIExit.failed
        case .failed:
            o.err("Colima gave no list of profiles. To find the cause, run: colima list")
            return CLIExit.failed
        case .listed(let rows):
            if let message = unknownProfileMessage(p, rows: rows) {
                o.err(message)
                return CLIExit.failed
            }
        }
        // Another action of this profile can run: ColimaBar, a terminal, or a
        // second command. Wait for it, then look again.
        switch await waitForOtherActions(p, output: o) {
        case .free: break
        case .timedOut:
            o.err("Another action of the profile \(p) did not end in 15 minutes.")
            return CLIExit.failed
        case .cancelled:
            return CLIExit.interrupted
        }
        list = await CLIStatusProbe.list()
        guard case .listed(let rows) = list else {
            o.err("Colima gave no list of profiles. To find the cause, run: colima list")
            return CLIExit.failed
        }
        if let note = alreadyDoneMessage(action, profile: p, rows: rows) {
            o.out(note)
            return CLIExit.done
        }

        let result = await Shell.run(
            [Paths.ctl, action.rawValue], timeout: 900, extraEnv: action.environment(profile: p, expectRunning: nil),
            cancellable: true)
        for line in notifications(in: result.out) { o.err(line) }
        if Task.isCancelled { return CLIExit.interrupted }
        let code = CLIExit.forScript(status: result.status)
        switch code {
        case CLIExit.locked:
            o.err("Another VM action of the profile \(p) holds its lock. Try again when it ends.")
            return code
        case CLIExit.failed:
            o.err(
                "The action \(action.rawValue) failed for the profile \(p). See ~/.cache/colima-bar/ctl.log. To find the cause, run: colimabar doctor"
            )
            return code
        default: break
        }
        if action != .stop {
            var runtime = ""
            if case .listed(let after) = await CLIStatusProbe.list() { runtime = after[p]?.runtime ?? "" }
            if needsReadinessWait(runtime: runtime) {
                let ready = await ReadinessGate.wait(probe: ReadinessGate.dockerProbe(socketPath: Paths.socket(p)))
                if Task.isCancelled { return CLIExit.interrupted }
                guard ready else {
                    o.err(
                        "The profile \(p) started, but Docker is not ready after \(Int(ReadinessGate.timeout)) seconds. To find the cause, run: colimabar doctor"
                    )
                    return CLIExit.failed
                }
            }
        }
        o.out("The profile \(p) \(action == .start ? "started" : action == .stop ? "stopped" : "restarted").")
        return CLIExit.done
    }

    /// The text of each `COLIMABAR_NOTIFY:` line of the script output. The
    /// app shows them as notifications. The command prints them.
    static func notifications(in output: String) -> [String] {
        let prefix = "COLIMABAR_NOTIFY:"
        return output.split(separator: "\n").filter { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }
    }

    /// The error for a profile that Colima does not list, or nil. A name with
    /// a typo must not make a new VM. Only default can start from nothing.
    static func unknownProfileMessage(_ p: String, rows: [String: CLIStatus.Row]) -> String? {
        guard p != "default", rows[p] == nil else { return nil }
        return "The profile \(p) does not exist. To see the profiles, run: colima list"
    }

    /// The text for a VM that already has the state that `action` makes, or
    /// nil. A profile that Colima does not list counts as stopped.
    static func alreadyDoneMessage(_ action: CtlAction, profile p: String, rows: [String: CLIStatus.Row]) -> String? {
        let status = rows[p]?.status
        if action == .start, status == "Running" { return "The profile \(p) is already running." }
        if action == .stop, status == nil || status == "Stopped" { return "The profile \(p) is already stopped." }
        return nil
    }

    /// Only the docker runtime has a docker socket to wait for.
    static func needsReadinessWait(runtime: String) -> Bool {
        ColimaModel.hasDockerSocket(runtime: runtime)
    }

    enum Wait { case free, timedOut, cancelled }

    /// The label of the action that holds `profile`, or nil: a busy marker
    /// or a `colima start` of another process.
    static func busyAction(_ p: String) async -> String? {
        if let label = CLIStatusProbe.busyLabel(profile: p) { return label }
        return await Task.detached(operation: { ColimaModel.colimaStartRunning(p) }).value ? "Starting" : nil
    }

    /// Waits while a busy marker or a `colima start` holds the profile. It
    /// looks once a second. On a terminal, it says what it waits for.
    /// `busy` and `sleep` are parameters so a test can use its own.
    static func waitForOtherActions(
        _ p: String, output o: CLIOutput, seconds: Int = waitSeconds,
        busy: (String) async -> String? = { await busyAction($0) },
        sleep: (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    ) async -> Wait {
        var announced: String?
        for _ in 0..<seconds {
            if Task.isCancelled { return .cancelled }
            guard let label = await busy(p) else { return .free }
            if o.isTerminal, announced != label {
                announced = label
                o.err("Waiting for: \(label) \(p)")
            }
            await sleep(.seconds(1))
        }
        return .timedOut
    }

    /// True if the app runs. The question goes to the system, not to the
    /// status file: an older app or an unwritable cache leaves no valid file.
    /// The command itself has the bundle ID of the app, so it does not count.
    /// It has no activation policy (prohibited).
    static func appIsRunning() -> Bool {
        NSRunningApplication.runningApplications(withBundleIdentifier: AppDelegate.bundleID)
            .contains { $0.processIdentifier != getpid() && !$0.isTerminated && $0.activationPolicy != .prohibited }
    }

    /// Opens the dashboard. A reopen of a running app shows it. If the app
    /// does not run, the first open starts it, and a second open asks it to
    /// show the dashboard once it runs. The status file of the app is only a
    /// hint that the app is ready. `isRunning`, `hasStatusFile`, `open` and
    /// `sleep` are parameters so a test can use its own.
    static func openDashboard(
        output o: CLIOutput, isRunning: () -> Bool = { appIsRunning() },
        hasStatusFile: () -> Bool = { AppStatusFile.read() != nil },
        open: () async throws -> Void = { try await launchApp() },
        sleep: (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    ) async -> Int32 {
        let wasRunning = isRunning()
        do {
            try await open()
        } catch {
            o.err("ColimaBar could not open the app: \(error.localizedDescription)")
            return CLIExit.failed
        }
        guard !wasRunning else { return CLIExit.done }
        // 10 seconds for the app to start.
        for _ in 0..<100 where !isRunning() {
            if Task.isCancelled { return CLIExit.interrupted }
            await sleep(.milliseconds(100))
        }
        guard isRunning() else {
            o.err("ColimaBar did not start in 10 seconds.")
            return CLIExit.failed
        }
        // The app writes its status file when it is ready. Wait up to 3 seconds for it.
        for _ in 0..<30 where !hasStatusFile() {
            if Task.isCancelled { return CLIExit.interrupted }
            await sleep(.milliseconds(100))
        }
        do {
            try await open()
        } catch {
            o.err("ColimaBar could not open the dashboard: \(error.localizedDescription)")
            return CLIExit.failed
        }
        return CLIExit.done
    }

    private static func launchApp() async throws {
        _ = try await NSWorkspace.shared.openApplication(
            at: Bundle.main.bundleURL, configuration: NSWorkspace.OpenConfiguration())
    }
}
