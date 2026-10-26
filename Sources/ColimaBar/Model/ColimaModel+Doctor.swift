import Foundation
import os

private let doctorLog = Logger(category: "doctor")

/// Doctor: checks of the setup, and the fixes for them. Doctor runs only on
/// request: the Run checks button, or the Doctor page when the last report
/// is old. It never runs from the heartbeat. The checks send no notification.
/// A fix sends one with its result.
extension ColimaModel {
    /// The report of the selected profile, or nil if there is none yet. A
    /// report of another profile does not count.
    var currentDoctorReport: DoctorReport? {
        doctorReport.flatMap { $0.profile == profile ? $0 : nil }
    }

    /// The hint for the stopped screen: why Doctor may help, or nil.
    var doctorHint: String? {
        guard state == .stopped else { return nil }
        return DoctorRules.stoppedHint(
            status: profiles.first { $0.name == profile }?.status, startFailed: startFailed)
    }

    /// Runs the checks if there is no report yet, or if it is old. The Doctor
    /// page calls it when it opens.
    func runDoctorIfStale() async {
        if let r = currentDoctorReport, !r.isStale(now: Date()) { return }
        await runDoctor()
    }

    /// Runs all checks. One run at a time. A profile switch during the run
    /// drops its result. A request during a run makes the run start once more
    /// when it ends, so the new profile gets its report.
    func runDoctor() async {
        guard !isDoctorRunning else {
            isDoctorRunQueued = true
            return
        }
        setDoctorRunning(true)
        await collectUntilDone()
        setDoctorRunning(false)
    }

    private func collectUntilDone() async {
        repeat {
            isDoctorRunQueued = false
            await collectDoctor()
        } while isDoctorRunQueued
    }

    private func collectDoctor() async {
        let p = profile
        let gen = generation
        // The status check reads the fresh `colima list`.
        let listed = await refreshStatus()
        guard gen == generation else { return }
        let routes = await Routing.status()
        let current = Routing.currentContext()
        let limaDir = Paths.limaDir
        let running = state == .running
        let runtime = vm.runtime
        async let tools = DoctorProbe.tools()
        async let existing = DoctorProbe.existingContexts()
        async let shell = DoctorProbe.shellHost()
        async let credentials = DoctorProbe.credentials()
        async let plugins = DoctorProbe.plugins()
        async let stale = DoctorProbe.staleFiles(
            profile: p, limaDir: limaDir, daemonPidFile: "\(Paths.profileDir(p))/daemon/daemon.pid")
        async let disk = DoctorProbe.disk(profile: p, running: running, runtime: runtime, limaDir: limaDir)
        let net = settings(of: p)
        let hasSocket = Self.hasDockerSocket(runtime: runtime)
        async let ports = Self.doctorPorts(profile: p, running: running, hasSocket: hasSocket, settings: net)
        async let dns = Self.doctorDNS(profile: p, running: running, settings: net)
        var inputs = DoctorInputs()
        inputs.profile = p
        inputs.home = Paths.home
        inputs.autoStart = autoStart
        inputs.stableHost = Routing.stableHost
        inputs.routes = DoctorInputs.Routes(
            launchdHost: routes.launchdHost, testcontainersHost: routes.testcontainersHost)
        inputs.context = DoctorInputs.DockerContext(current: current, existing: await existing)
        inputs.vm = DoctorInputs.VM(
            selected: profiles.first { $0.name == p }, others: profiles, listFailed: !listed)
        inputs.dockerConfigUnreadable = DoctorProbe.dockerConfigUnreadable()
        inputs.tools = await tools
        inputs.lastGoodVersions = goodStart(for: p)
        inputs.shell = await shell
        inputs.credentials = await credentials
        inputs.plugins = await plugins
        let scan = await stale
        inputs.staleFiles = scan.files
        inputs.staleListFailure = scan.failure
        inputs.staleUnparsed = scan.unparsed
        inputs.disk = await disk
        inputs.portForwarder = net.forwarder
        inputs.dnsOverride = net.dnsOverride
        let mac = NetworkObserver.readCurrent()
        if mac == nil { log.error("the DNS setup of the Mac was not read") }
        inputs.macSplitDomains = mac?.splitDomains ?? []
        inputs.ports = await ports
        inputs.dns = await dns
        guard gen == generation else { return }
        publishDoctor(report: DoctorReport(profile: p, date: Date(), results: DoctorRules.evaluate(inputs)))
    }

    /// Makes one fix, then runs the checks again. A debug run changes
    /// nothing, so it makes no fix.
    func applyFix(_ fix: DoctorFix) {
        guard !isDebug, !isDoctorRunning else { return }
        switch fix {
        case .repair:
            repairProfile()
        case .copyLine:
            run(.copyEnv)
        case .restartVM:
            restartForNetworkFix()
        default:
            setDoctorRunning(true)
            Task {
                await perform(fix)
                await collectUntilDone()
                setDoctorRunning(false)
            }
        }
    }

    private func perform(_ fix: DoctorFix) async {
        switch fix {
        case .useColimabar:
            if await Routing.useOwnContext() {
                // The user clicked the fix, so no earlier pick stays.
                dockerContextChoice = nil
                notify("Doctor switched the docker context to colimabar.")
            } else {
                doctorLog.error("Doctor: use colimabar failed")
                notify("Doctor could not switch the docker context. See the log for the reason.")
            }
            await refreshRouting()
        case .setRoutes:
            let applied = await Routing.apply(selected: profile, choice: dockerContextChoice)
            if applied.any {
                notify("Doctor set the routes for apps and testcontainers.")
            } else {
                doctorLog.error("Doctor: set routes changed nothing")
                notify("Doctor changed no route. See the log for the reason.")
            }
            await refreshRouting()
        case .useOsxkeychain:
            editDockerConfig(done: "Doctor set credsStore to osxkeychain.") {
                DockerConfig.settingCredsStore("osxkeychain", in: $0)
            }
        case .addPluginFolder:
            editDockerConfig(done: "Doctor added \(DoctorRules.homebrewPluginFolder) to the docker plugin folders.") {
                DockerConfig.addingPluginDir(DoctorRules.homebrewPluginFolder, in: $0)
            }
        case .useSSHForwarder:
            await useSSHForwarder()
        case .useMacDNS:
            await useMacDNS()
        case .copyLine, .repair, .restartVM:
            break
        }
    }

    private func editDockerConfig(done: String, _ transform: (Data) -> Data?) {
        let path = Paths.dockerConfig(env: ProcessInfo.processInfo.environment, home: Paths.home)
        switch DockerConfigFile.edit(path: path, transform) {
        case .changed(let backup):
            doctorLog.notice("Doctor changed the docker config file (backup: \(backup ?? "none", privacy: .public))")
            notify(backup.map { "\(done) A backup is at \($0)." } ?? done)
        case .invalid:
            doctorLog.error("Doctor: the docker config file is not a JSON object")
            notify("The docker config file is not valid JSON. Doctor did not change it.")
        case .failed(let why):
            doctorLog.error("Doctor: docker config file not changed: \(why, privacy: .public)")
            notify("Doctor could not change the docker config file: \(why)")
        }
    }

    /// Runs `colima-ctl.sh repair` for the selected profile, then the checks
    /// again. The script asks first, so the popover closes.
    func repairProfile() {
        guard !isDebug, busy == nil else { return }
        let p = profile
        let running = isRunning(profile: p)
        dismissPopover()
        let label = markBusy(.repair, p, running: running)
        Task {
            await execute(.repair, [], profile: p, label: label, expectRunning: running)
            await runDoctor()
        }
    }
}
