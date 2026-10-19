import Foundation

/// The network checks: do the published ports answer on the Mac, and does the
/// VM resolve host names? They run only while the VM already runs, and they
/// never go through a proxy socket, so they never start a VM. They run
/// after a wake, when the dashboard opens, when the DNS setup of the Mac
/// changes, in Doctor and on the Check again button. They never poll.
extension ColimaModel {
    /// What colima.yaml says about the checks.
    struct NetworkSettings: Equatable, Sendable {
        /// "ssh" if the file has no value.
        var forwarder = "ssh"
        /// `network.dns` has servers.
        var dnsOverride = false
        /// Kubernetes with `network.address` on: Colima ignores the ports 80 and 443.
        var kubernetesWithAddress = false
    }

    /// The wait after the last network change, so a VPN that connects in
    /// steps gives one check.
    static let networkDebounce: Duration = .seconds(10)
    /// The wait after a wake, so the network is back.
    static let afterWakeDelay: Duration = .seconds(15)
    /// The wait before the second probe of a broken port.
    static let portConfirmDelay: Duration = .seconds(5)
    /// The wait before the second look-up of a failed DNS check.
    static let dnsConfirmDelay: Duration = .seconds(20)
    /// An open dashboard checks the ports again if the last check is older.
    nonisolated static let openCheckAge: TimeInterval = 5 * 60

    nonisolated static func networkSettings(yaml: String?) -> NetworkSettings {
        guard let yaml else { return NetworkSettings() }
        let read = VMSettings.read(yaml)
        return NetworkSettings(
            forwarder: read.portForwarder, dnsOverride: !read.dnsServers.isEmpty,
            kubernetesWithAddress: VMConfig.parse(yaml).kubernetes && read.address)
    }

    /// The running profiles with a valid name, except the `blocked` ones: an
    /// action or an auto-start reports its own failures.
    nonisolated static func networkProfiles(_ rows: [ProfileRow], blocked: Set<String>) -> [String] {
        rows.filter { $0.isRunning && ProfileName.isValid($0.name) && !blocked.contains($0.name) }.map(\.name)
    }

    /// The longest a sleep pauses the checks of network changes. A wake path
    /// that never ends (cancelled, or stuck) must not stop them for good.
    nonisolated static let networkPauseLimit: TimeInterval = 30 * 60

    /// True if a sleep started less than `networkPauseLimit` ago and the
    /// after-wake path has not run yet.
    nonisolated static func networkPauseActive(pausedAt: Date?, now: Date) -> Bool {
        guard let pausedAt else { return false }
        return now.timeIntervalSince(pausedAt) < networkPauseLimit
    }

    /// True if the dashboard opens and the last check is old or missing.
    nonisolated static func needsOpenCheck(last: Date?, now: Date) -> Bool {
        guard let last else { return true }
        return now.timeIntervalSince(last) > openCheckAge
    }

    /// The settings of a profile from colima.yaml. A file that cannot be read
    /// gives the defaults (the ssh forwarder, no DNS servers), so no fix that
    /// needs the file is offered. The failure goes to the log.
    func settings(of p: String) -> NetworkSettings {
        do {
            return Self.networkSettings(yaml: try String(contentsOfFile: Paths.config(p), encoding: .utf8))
        } catch {
            log.error(
                "colima.yaml of profile \(p, privacy: .public) was not read: \(error.localizedDescription, privacy: .public)"
            )
            return NetworkSettings()
        }
    }

    /// Applies one result of a check to the throttle. Returns true if a
    /// notification may post. An `inconclusive` result changes nothing. A
    /// result that is not `broken` lets the next problem notify at once. A
    /// problem that stays notifies once for each window of the throttle.
    nonisolated static func networkAlertAllowed(
        broken: Bool, inconclusive: Bool, key: String, notify: Bool, isDebug: Bool, throttle: inout AlertThrottle
    ) -> Bool {
        guard !inconclusive else { return false }
        guard broken else {
            throttle.reset(key)
            return false
        }
        return notify && !isDebug && throttle.allow(key)
    }

    /// True if the VM gave no usable answer for the ports, so the report must
    /// not replace the earlier one.
    nonisolated static func portsInconclusive(_ r: PortHealth.Report) -> Bool { r.vmFailure != nil }

    /// True if the report cannot show that the ports are fine: no port is
    /// broken, and the VM gave no answer for some ports.
    nonisolated static func portsUndecided(_ r: PortHealth.Report) -> Bool { !r.isBroken && !r.unknown.isEmpty }

    /// True if the DNS verdict says nothing about a working or a broken VM.
    nonisolated static func dnsInconclusive(_ v: DNSHealth.Verdict) -> Bool { v == .unknown || v == .macOffline }

    /// False when a check must stop quietly: it was cancelled, an action or a
    /// start runs, or the VM is not running.
    private func canCheckNetwork(_ p: String) -> Bool {
        !Task.isCancelled && !isBlockedForSleepCheck(p) && isRunning(profile: p)
    }

    /// True if the dashboard shows the notice: the selected VM runs and a check found a problem.
    var hasNetworkProblem: Bool {
        state == .running && (portHealth[profile]?.isBroken == true || dnsHealth[profile]?.isBroken == true)
    }

    // MARK: Triggers

    /// A debug run does not call this: it never watches the network.
    func startNetworkObserver() {
        let observer = NetworkObserver()
        observer.onChange = { [weak self] _ in self?.networkChanged() }
        networkObserver = observer
    }

    /// The DNS setup of the Mac changed. Wait until it is quiet, then check.
    private func networkChanged() {
        // A sleep or a dark wake: the after-wake check runs when the Mac is awake.
        guard !Self.networkPauseActive(pausedAt: networkPausedAt, now: Date()) else { return }
        networkDebounce?.cancel()
        networkDebounce = Task {
            try? await Task.sleep(for: Self.networkDebounce)
            guard !Task.isCancelled else { return }
            await checkDNSOfRunningProfiles()
        }
    }

    /// The Mac is about to sleep: stop the wait and the checks of a network change.
    func pauseNetworkChecks() {
        networkPausedAt = Date()
        networkDebounce?.cancel()
        networkDebounce = nil
    }

    /// The after-wake path ran: network changes start a check again.
    func resumeNetworkChecks() { networkPausedAt = nil }

    private func checkDNSOfRunningProfiles() async {
        let blocked = Set(profiles.map(\.name).filter { isBlockedForSleepCheck($0) })
        let names = Self.networkProfiles(profiles, blocked: blocked)
        await withTaskGroup(of: Void.self) { group in
            for p in names { group.addTask { await self.checkDNS(p, notify: true) } }
        }
    }

    /// The end of the check after a wake, when Docker answers. A new sleep
    /// cancels it.
    func checkPortsAfterWake(_ p: String) async {
        try? await Task.sleep(for: Self.afterWakeDelay)
        guard canCheckNetwork(p) else { return }
        await checkPorts(p, notify: true)
    }

    /// The dashboard opened. It shows a notice, and sends no notification.
    func checkPortsOnOpen() {
        guard !isDebug else { return }
        let p = profile
        Task {
            guard isRunning(profile: p), Self.needsOpenCheck(last: networkChecked[p], now: Date()) else { return }
            await checkPorts(p, notify: false)
        }
    }

    /// The Check again button of the notice. The notice shows the progress.
    func checkNetworkAgain() {
        let p = profile
        guard isRunning(profile: p), !isCheckingNetwork(p) else { return }
        Task {
            async let ports: Void = checkPorts(p, notify: false)
            async let dns: Void = checkDNS(p, notify: false)
            _ = await (ports, dns)
        }
    }

    /// True while a check of the profile runs. The notice shows "Checking…".
    func isCheckingNetwork(_ p: String) -> Bool { networkChecking.contains(p) }

    private func beginCheck(_ key: String, of p: String) -> Bool {
        guard networkRunning.insert(key).inserted else { return false }
        setNetworkChecking(networkChecking.union([p]))
        return true
    }

    private func endCheck(_ key: String, of p: String) {
        networkRunning.remove(key)
        if !networkRunning.contains("ports|\(p)"), !networkRunning.contains("dns|\(p)") {
            setNetworkChecking(networkChecking.subtracting([p]))
        }
    }

    // MARK: Checks

    /// Probes the published ports of a profile. A broken port needs a second
    /// probe after a short wait before it counts. A check that gets no usable
    /// answer keeps the earlier report and the throttle as they are.
    func checkPorts(_ p: String, notify: Bool) async {
        let key = "ports|\(p)"
        guard beginCheck(key, of: p) else { return }
        defer { endCheck(key, of: p) }
        let net = settings(of: p)
        let runtime = profiles.first { $0.name == p }?.runtime ?? ""
        guard Self.hasDockerSocket(runtime: runtime), canCheckNetwork(p) else { return }
        guard net.forwarder != "none" else {
            publishPorts(nil, for: p)
            return
        }
        let probe = await NetworkProbe.ports(profile: p, kubernetesWithAddress: net.kubernetesWithAddress)
        guard canCheckNetwork(p) else { return }
        guard case .checked(var report) = probe else {
            log.error("ports check of profile \(p, privacy: .public): docker did not answer")
            setCheckError("ColimaBar could not check the ports: Docker did not answer.", key: key)
            return
        }
        if let status = report.vmFailure {
            log.error("ports check of profile \(p, privacy: .public): colima ssh exit \(status, privacy: .public)")
            setCheckError("ColimaBar could not check the ports: the VM did not answer.", key: key)
            return
        }
        if report.isBroken {
            try? await Task.sleep(for: Self.portConfirmDelay)
            guard canCheckNetwork(p) else { return }
            report = PortHealth.confirmed(report, host: await PortProbe.check(ports: report.broken))
            guard canCheckNetwork(p) else { return }
        }
        setCheckError(nil, key: key)
        networkChecked[p] = Date()
        publishPorts(report, for: p)
        if report.isBroken {
            log.error("published ports of profile \(p, privacy: .public) do not answer on the Mac")
        }
        guard
            Self.networkAlertAllowed(
                broken: report.isBroken, inconclusive: Self.portsUndecided(report), key: key, notify: notify,
                isDebug: isDebug, throttle: &networkAlerts)
        else { return }
        Notifier.shared.post(
            PortHealth.notificationText(profile: p, ports: report.broken, forwarder: net.forwarder),
            restartProfile: p)
    }

    /// Looks up a name in the VM and on the Mac. A failure needs a second
    /// look-up after a wait before it counts. One notification for each
    /// window, also when the problem stays through VPN changes. A look-up
    /// with no usable answer keeps the earlier report and the throttle.
    func checkDNS(_ p: String, notify: Bool) async {
        let key = "dns|\(p)"
        guard beginCheck(key, of: p) else { return }
        defer { endCheck(key, of: p) }
        guard canCheckNetwork(p) else { return }
        let override = settings(of: p).dnsOverride
        var report = await NetworkProbe.dns(profile: p, override: override)
        guard canCheckNetwork(p) else { return }
        if report.isBroken {
            try? await Task.sleep(for: Self.dnsConfirmDelay)
            guard canCheckNetwork(p) else { return }
            report = await NetworkProbe.dns(profile: p, override: override)
            guard canCheckNetwork(p) else { return }
        }
        let inconclusive = Self.dnsInconclusive(report.verdict)
        if !inconclusive { publishDNS(report, for: p) }
        guard case .broken(let isOverride) = report.verdict else {
            _ = Self.networkAlertAllowed(
                broken: false, inconclusive: inconclusive, key: key, notify: notify, isDebug: isDebug,
                throttle: &networkAlerts)
            return
        }
        log.error("the VM of profile \(p, privacy: .public) cannot resolve host names")
        guard
            Self.networkAlertAllowed(
                broken: true, inconclusive: false, key: key, notify: notify, isDebug: isDebug, throttle: &networkAlerts)
        else { return }
        Notifier.shared.post(DNSHealth.notificationText(profile: p, override: isOverride), restartProfile: p)
    }

    // MARK: State

    private func publishPorts(_ report: PortHealth.Report?, for p: String) {
        var all = portHealth
        all[p] = report
        setPortHealth(all)
    }

    private func setCheckError(_ text: String?, key: String) {
        var all = networkCheckErrors
        all[key] = text
        setNetworkCheckErrors(all)
    }

    private func publishDNS(_ report: DNSHealth.Report?, for p: String) {
        var all = dnsHealth
        all[p] = report
        setDNSHealth(all)
    }

    /// Drops what the checks know about a profile and lets a new alert through.
    func forgetNetworkHealth(_ p: String) {
        publishPorts(nil, for: p)
        publishDNS(nil, for: p)
        networkChecked[p] = nil
        setCheckError(nil, key: "ports|\(p)")
        networkAlerts.reset("ports|\(p)")
        networkAlerts.reset("dns|\(p)")
    }

    /// Drops the checks of a profile that does not run any more.
    func pruneNetworkHealth() {
        let running = Set(profiles.filter(\.isRunning).map(\.name))
        for p in Set(portHealth.keys).union(dnsHealth.keys).union(networkChecked.keys) where !running.contains(p) {
            forgetNetworkHealth(p)
        }
    }

    // MARK: Fixes

    /// The Restart fix of Doctor: the same rules as the Restart of an alert
    /// (`alertRestart`), then the checks of Doctor again. A rule that stops
    /// the restart tells the user why.
    func restartForNetworkFix() {
        guard !isDebug else { return }
        let p = profile
        guard !updateRestarting else {
            log.error("network fix: restart of profile \(p, privacy: .public) skipped, an update restarts the app")
            Notifier.shared.post(AfterSleepCheck.restartBusyText(profile: p))
            return
        }
        switch alertRestartDecision(p) {
        case .restart:
            if CtlAction.restart.showsDialog(running: true) { dismissPopover() }
            let label = markBusy(.restart, p, running: true)
            Task {
                await execute(.restart, [], profile: p, label: label, expectRunning: true)
                await runDoctor()
            }
        case .missing:
            log.error("network fix: profile \(p, privacy: .public) has no colima.yaml")
            Notifier.shared.post(AfterSleepCheck.restartMissingText(profile: p))
        case .busy:
            log.error("network fix: restart of profile \(p, privacy: .public) skipped, an action runs")
            Notifier.shared.post(AfterSleepCheck.restartBusyText(profile: p))
        case .stopped:
            log.error("network fix: restart of profile \(p, privacy: .public) skipped, the VM is stopped")
            Notifier.shared.post(AfterSleepCheck.restartStoppedText(profile: p))
        }
    }

    /// Sets `portForwarder: ssh` and restarts the VM (see `applyVMSettings`).
    func useSSHForwarder() async {
        let p = profile
        switch await applyVMSettings(VMSettingsChange(portForwarder: "ssh"), profile: p) {
        case .applied: forgetNetworkHealth(p)
        case .alreadyThere: checkNetworkAgain()
        default: break
        }
    }

    /// Clears `network.dns`, so the VM uses the DNS of the Mac, and restarts the VM.
    /// It does not copy the servers of the Mac: they change with the network.
    func useMacDNS() async {
        let p = profile
        switch await applyVMSettings(VMSettingsChange(dnsServers: []), profile: p) {
        case .applied: forgetNetworkHealth(p)
        case .alreadyThere: checkNetworkAgain()
        default: break
        }
    }
}

extension ColimaModel {
    /// The ports probe for Doctor. Only a running VM is probed.
    nonisolated static func doctorPorts(
        profile: String, running: Bool, hasSocket: Bool, settings: NetworkSettings
    ) async -> PortHealth.Probe {
        guard running else { return .vmStopped }
        guard hasSocket else { return .notDocker }
        guard settings.forwarder != "none" else { return .off }
        return await NetworkProbe.ports(profile: profile, kubernetesWithAddress: settings.kubernetesWithAddress)
    }

    /// The DNS probe for Doctor. Only a running VM is probed.
    nonisolated static func doctorDNS(profile: String, running: Bool, settings: NetworkSettings) async
        -> DoctorInputs.DNS
    {
        guard running else { return .vmStopped }
        return .checked(await NetworkProbe.dns(profile: profile, override: settings.dnsOverride))
    }
}
