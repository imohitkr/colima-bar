import AppKit
import Foundation

/// The `colimabar` command. `scripts/colimabar.sh` runs the binary of the
/// app with `--cli`, and `AppDelegate.main()` calls `main(_:)` before it
/// creates `NSApplication`. So the command has no Dock icon and no status
/// item, and it never reaches the code that makes the app a single
/// instance or the login item.
///
/// The command gets its facts from `colima list -j`, the busy marker, the
/// settings of the app and the status file of the app (`AppStatusFile`). It
/// changes the system only through `colima-ctl.sh` (start, stop, restart)
/// and the file that the user names (diagnostics). `doctor` and
/// `diagnostics` use a read-only `ColimaModel`.
@MainActor
enum CLIRunner {
    private static var signalSources: [DispatchSourceSignal] = []
    private static var receivedSignal: Int32?

    /// Runs the command and exits. `args` are the arguments after `--cli`.
    static func main(_ args: [String]) -> Never {
        guard Bundle.main.bundleIdentifier == AppDelegate.bundleID else {
            CLIOutput.terminal.err("colimabar must run from ColimaBar.app. Use the command inside the app bundle.")
            exit(CLIExit.failed)
        }
        let task = Task { @MainActor in
            let code = await run(args, output: .terminal)
            // A signal ended the work: say so with the shell's code.
            exit(receivedSignal.map(CLIExit.forSignal) ?? code)
        }
        trapSignals(cancelling: task)
        dispatchMain()
    }

    /// SIGINT and SIGTERM cancel the work. A running `colima-ctl.sh` then
    /// gets SIGTERM, removes its lock and busy marker, and exits.
    private static func trapSignals(cancelling task: Task<Void, Never>) {
        signal(SIGPIPE, SIG_IGN)
        for sig in [SIGINT, SIGTERM] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            // After dispatchMain(), the main queue does not always run on the
            // thread that MainActor.assumeIsolated expects, so hop with a task.
            source.setEventHandler { @Sendable in
                Task { @MainActor in
                    receivedSignal = sig
                    task.cancel()
                }
            }
            source.resume()
            signalSources.append(source)
        }
    }

    /// Parses `args`, runs the command and returns the exit code.
    static func run(_ args: [String], output: CLIOutput) async -> Int32 {
        switch CLIParser.parse(args) {
        case .usageError(let message):
            output.err(CLIHelp.usageError(message))
            return CLIExit.usage
        case .run(let request):
            return await run(request, output: output)
        }
    }

    static func run(_ request: CLIRequest, output o: CLIOutput) async -> Int32 {
        switch request.command {
        case .help:
            o.out(CLIHelp.text)
            return CLIExit.done
        case .version:
            o.out(CLIHelp.version(AppDelegate.version))
            return CLIExit.done
        case .status: return await status(request, output: o)
        case .start: return await vmAction(.start, request, output: o)
        case .stop: return await vmAction(.stop, request, output: o)
        case .restart: return await vmAction(.restart, request, output: o)
        case .open: return await openDashboard(output: o)
        case .doctor: return await doctor(request, output: o)
        case .diagnostics: return await diagnostics(request, output: o)
        }
    }

    // MARK: - Commands that only read

    private static func status(_ request: CLIRequest, output o: CLIOutput) async -> Int32 {
        let profile = CLIProfile.resolve(explicit: request.profile)
        let inputs = await CLIStatusProbe.gather(profile: profile, selected: CLIProfile.selected())
        let status = CLIStatus.make(inputs)
        o.out(request.json ? status.json() : status.text(home: Paths.home))
        return CLIExit.forStatus(status.vm.state)
    }

    private static func doctor(_ request: CLIRequest, output o: CLIOutput) async -> Int32 {
        let model = ColimaModel(profile: CLIProfile.resolve(explicit: request.profile), readOnly: true)
        await model.runDoctor()
        guard let report = model.doctorReport else {
            o.err("Doctor gave no report.")
            return CLIExit.failed
        }
        let doctor = CLIDoctorReport(version: AppDelegate.version, report: report, home: Paths.home)
        o.out(request.json ? doctor.json() : doctor.text())
        return CLIExit.forDoctor(report)
    }

    private static func diagnostics(_ request: CLIRequest, output o: CLIOutput) async -> Int32 {
        let target = CLIDiagnosticsPath.resolve(
            argument: request.path, cwd: FileManager.default.currentDirectoryPath, date: Date())
        let url: URL
        switch target {
        case .failure(let failure):
            o.err(failure.message)
            return CLIExit.failed
        case .success(let value):
            url = value
        }
        let model = ColimaModel(profile: CLIProfile.resolve(explicit: request.profile), readOnly: true)
        let listed = await model.refreshStatus()
        // replace: false. A file that appeared since the early check stays.
        if let error = await model.saveDiagnostics(to: url, stateKnown: listed, replace: false) {
            if let failure = error as? CLIDiagnosticsPath.Failure {
                o.err(failure.message)
            } else {
                o.err("ColimaBar could not write \(url.path): \(error.localizedDescription)")
            }
            return CLIExit.failed
        }
        o.out(url.path)
        o.err(DiagnosticsBundle.notice)
        return CLIExit.done
    }
}
