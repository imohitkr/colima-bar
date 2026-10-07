import AppKit
import Foundation
import Observation
import os

/// Single source of truth for the dashboard. Every property is only assigned
/// when its value actually changed, so SwiftUI redraws just the cells whose
/// text differs and nothing shifts while the popover is open.
///
/// Container data comes straight from the Docker Engine API on the selected
/// profile's socket (no process per refresh, streaming stats). Colima itself
/// has no API, so VM facts come from `colima list -j`, run only when the VM
/// goes up/down, when a watched Colima directory changes, when the dashboard
/// opens and the last list is over a minute old, or when the last list is
/// over 5 minutes old.
@MainActor @Observable
final class ColimaModel {
    private(set) var state: VMState = .unknown {
        didSet { if state != oldValue { wakeHeartbeat() } }
    }
    private(set) var busy: String?
    private(set) var vm = VMInfo()
    private(set) var isRosettaEnabled = false
    private(set) var isKubernetesEnabled = false
    private(set) var containers: [Container] = [] {
        didSet { updateDerivedLists() }
    }
    private(set) var stats: [String: Stat] = [:]  // by container id
    private(set) var cpuHistory: [Double] = []  // % of VM CPU used by containers
    private(set) var memHistory: [Double] = []  // % of VM memory used by containers
    private(set) var df: [DFRow] = []
    private(set) var images: [ImageRow] = []
    private(set) var volumes: [VolumeRow] = []
    private(set) var profiles: [ProfileRow] = []
    /// VM actions that run for profiles other than the selected one, by
    /// profile: the busy label, for example "Starting". The profile menu
    /// shows them. The selected profile uses `busy`.
    private(set) var profileActions: [String: String] = [:]
    private(set) var routing = Routing.Status()
    /// The dashboard's selected tab, set by DashboardView. No view reads it
    /// here; it tells the model which costly data is on screen.
    @ObservationIgnored var dashboardTab: DashboardTab = .containers {
        didSet {
            guard dashboardTab != oldValue, visibleCount > 0 else { return }
            // An event changed disk use while no tab showed it: the rows are stale.
            if Self.showsDiskUsage(dashboardTab) { requestDF(urgent: diskDirty) }
            if dashboardTab == .system { Task { await refreshRouting() } }
        }
    }
    private(set) var alerts: [AlertItem] = []  // newest first, also shown in the dashboard
    var notificationsAllowed = true
    private(set) var idleSince: Date?

    var profile = Defaults.string(.profile) ?? "default" {
        didSet {
            guard profile != oldValue else { return }
            Defaults.set(profile, .profile)
            switchProfile(from: oldValue)
        }
    }
    var notifyOnCrash = Defaults.bool(.notifyOnCrash) ?? true {
        didSet {
            guard notifyOnCrash != oldValue else { return }
            Defaults.set(notifyOnCrash, .notifyOnCrash)
            syncKeeper()
        }
    }
    /// Keep the logs of removed containers that fail. It works only while
    /// crash alerts are on, because the alert opens the saved lines.
    var keepRemovedLogs = Defaults.bool(.keepRemovedLogs) ?? false {
        didSet {
            guard keepRemovedLogs != oldValue else { return }
            Defaults.set(keepRemovedLogs, .keepRemovedLogs)
            syncKeeper()
        }
    }
    /// The removed containers whose last lines `keeper` holds. The alerts
    /// strip reads it. It changes only when a buffer is kept or dropped.
    private(set) var savedLogIDs: Set<String> = []
    var autoStart = Defaults.bool(.autoStart) ?? true {
        didSet {
            guard autoStart != oldValue else { return }
            Defaults.set(autoStart, .autoStart)
            // A debug run must not change the proxy sockets.
            guard !isDebug else { return }
            autoStart ? proxy.start() : proxy.stop()
            profileProxies.setListening(autoStart)
        }
    }
    var autoStop = Defaults.bool(.autoStop) ?? false {
        didSet {
            Defaults.set(autoStop, .autoStop)
            idleSince = nil
            otherIdle = [:]
        }
    }
    var autoStopMinutes = Defaults.int(.autoStopMinutes).map(IdleMinutes.clamp) ?? 30 {
        didSet {
            let v = IdleMinutes.clamp(autoStopMinutes)
            if v != autoStopMinutes {
                autoStopMinutes = v
                return
            }
            Defaults.set(autoStopMinutes, .autoStopMinutes)
            idleSince = nil
            otherIdle = [:]
        }
    }
    var hideIconWhenStopped = Defaults.bool(.hideIconWhenStopped) ?? false {
        didSet { Defaults.set(hideIconWhenStopped, .hideIconWhenStopped) }
    }
    /// Set when the app is reopened from Spotlight/Finder while its icon is
    /// hidden. It keeps the icon visible until the dashboard opens. When the
    /// last dashboard surface closes, or the VM starts, it clears, so the icon
    /// hides again if Colima is still stopped.
    var revealIcon = false

    /// Only the menu bar icon hides; the process, the auto-start proxy and the
    /// light heartbeat keep running so `docker` still wakes the VM.
    var iconHidden: Bool {
        Self.hidesIcon(
            enabled: hideIconWhenStopped, revealed: revealIcon, state: state,
            busy: busy != nil, dashboardOpen: visibleCount > 0,
            otherProfileRunning: profiles.contains { $0.isRunning && $0.name != profile })
    }

    /// The first time the icon ever hides, say where it went and how to get it
    /// back. Only once per user, not once per hide or per launch.
    func noteIconHiddenOnce() {
        // Another instance (during a launch handover) may have just set the
        // flag: re-read it from disk, and claim it atomically with a file.
        CFPreferencesAppSynchronize(kCFPreferencesCurrentApplication)
        guard !(Defaults.bool(.toldIconHidden) ?? false) else { return }
        let marker = "\(Paths.cacheDir)/told-icon-hidden"
        let fd = Darwin.open(marker, O_CREAT | O_EXCL | O_WRONLY, 0o600)
        Defaults.set(true, .toldIconHidden)
        guard fd >= 0 else { return }  // someone else claimed it first
        close(fd)
        Notifier.shared.post(
            "The icon is hidden while Colima is stopped. It comes back when Colima starts. To show it now, open ColimaBar from Spotlight.",
            record: false)
    }

    /// Number of dashboard surfaces (popover, window) currently on screen.
    /// Live stats only stream while this is > 0.
    var visibleCount = 0 {
        didSet {
            guard (oldValue > 0) != (visibleCount > 0) else { return }
            if visibleCount == 0 { revealIcon = false }
            visibleCount > 0 ? becameVisible() : syncStatStreams()
            wakeHeartbeat()
        }
    }

    // Views and the menu bar icon read these many times per render. They are
    // stored, and recomputed only when `containers` changes.
    private(set) var running: [Container] = []
    private(set) var stopped: [Container] = []
    private(set) var unhealthyCount = 0
    var kubeContext: String { Paths.kubeContext(profile) }

    private(set) var api: DockerAPI
    let proxy: SocketProxy
    /// One proxy for each docker profile (see ProfileProxies).
    let profileProxies: ProfileProxies
    private let log = Logger(category: "model")
    // Internal bookkeeping that no view reads: writes skip observation.
    /// Closes the dashboard popover, so a dialog is not hidden behind it.
    /// AppDelegate sets it.
    @ObservationIgnored var dismissPopover: @MainActor () -> Void = {}
    /// The colima-ctl.sh actions that run now, for each profile. A running
    /// action (for example a prune that waits for its dialog) is not idle.
    @ObservationIgnored private var actionsInFlight: [String: Int] = [:]
    @ObservationIgnored private var events: StreamHandle?
    @ObservationIgnored private var statStreams: [String: StreamHandle] = [:]
    @ObservationIgnored private var latest: [String: Stat] = [:]  // written by stat streams, published once a second
    @ObservationIgnored private var tickTask: Task<Void, Never>?
    @ObservationIgnored private var tickSleep: Task<Void, Never>?  // the heartbeat's current sleep
    @ObservationIgnored private var containerRefresh: Task<Void, Never>?
    @ObservationIgnored private var reloadPending = false  // an event since the last refresh changed containers
    @ObservationIgnored private var dfGate = DFGate()
    @ObservationIgnored private var dfToken = 0  // bumps when dfGate resets; older df tasks then stop
    @ObservationIgnored private var diskDirty = false  // an event changed images, volumes or disk use
    @ObservationIgnored private var lastColima = Date.distantPast
    @ObservationIgnored private var lastPing = Date()
    @ObservationIgnored private var dirWatcher: ColimaDirWatcher?
    @ObservationIgnored private var isDebug = false
    @ObservationIgnored private var generation = 0  // bumps on profile switch; stale callbacks are ignored
    // Drops `colima list` results older than the last applied one.
    @ObservationIgnored private var statusOrder = LatestOnly()
    @ObservationIgnored private var isConfirmingAutoStop = false  // an auto-stop check runs a fresh list
    @ObservationIgnored private var localBusy: String?  // VM action launched here, marker not written yet
    // One wake at a time for each profile. The stable socket and the profile
    // socket can both ask to start the same profile.
    @ObservationIgnored private var wakes: [String: (token: Int, task: Task<Bool, Never>)] = [:]
    @ObservationIgnored private var wakeToken = 0
    // Auto-stop state of the running profiles other than the selected one.
    @ObservationIgnored private var otherIdle: [String: OtherIdle] = [:]
    // The colimabar-PROFILE contexts: the last applied and the next wanted set.
    @ObservationIgnored private var appliedContexts: [String: String]?
    @ObservationIgnored private var wantedContexts: [String: String]?
    @ObservationIgnored private var isApplyingContexts = false
    // The last set that ProfileContexts.apply failed for, and when.
    @ObservationIgnored private var contextsFailure: (wanted: [String: String], at: Date)?
    // Not observed: its buffers change with each log line.
    @ObservationIgnored private let keeper: RemovedLogKeeper
    private let historyLen = 60

    /// The dashboard keeps at most this many alerts.
    static let alertCap = 20
    /// A busy marker older than this was left behind by a killed script.
    nonisolated static let staleBusyMarkerAge: TimeInterval = 20 * 60
    /// How long a proxy wake waits for another start or stop to finish.
    static let startWaitSeconds = 300
    /// After a wake, Docker counts as ready after this many successful
    /// probes in a row.
    static let readinessStreak = 3
    /// The readiness check gives up after this time.
    static let readinessTimeout: TimeInterval = 60
    /// The pause between two readiness probes.
    static let readinessInterval: Duration = .milliseconds(500)
    /// Exit codes of a normal stop: no crash alert for them. 130 is SIGINT,
    /// 137 SIGKILL and 143 SIGTERM.
    nonisolated static let ignoredExitCodes: Set<String> = ["0", "130", "137", "143"]

    init() {
        let p = Defaults.string(.profile) ?? "default"
        let client = DockerAPI(socketPath: Paths.socket(p))
        api = client
        keeper = RemovedLogKeeper(api: client)
        proxy = SocketProxy(upstream: Paths.socket(p))
        proxy.apiVersion = Defaults.string(.apiVersion)
        profileProxies = ProfileProxies()
        profileProxies.apiVersion = proxy.apiVersion
        keeper.onChange = { [weak self] ids in self?.set(\.savedLogIDs, ids) }
        syncKeeper()
    }

    /// The keeper opens streams only while both settings are on.
    private func syncKeeper() {
        keeper.isEnabled = keepRemovedLogs && notifyOnCrash
    }

    func start(debug: Bool = false) {
        isDebug = debug
        if !debug {
            proxy.wake = { [weak self] in await self?.wakeForProxy() ?? false }
            if autoStart { proxy.start() } else { proxy.stop() }
            // The proxies appear with the first `colima list` (syncProfiles).
            profileProxies.wake = { [weak self] p in await self?.wakeForProxy(profile: p) ?? false }
            profileProxies.setListening(autoStart)
            Task {
                await Routing.apply()
                routing = await Routing.status()
            }
            dirWatcher = makeDirWatcher()
        }
        Task { await refreshAll() }
        lastPing = Date()
        tickTask = Task {
            while !Task.isCancelled {
                let interval = Self.tickInterval(state: state, busy: busy != nil, dashboardOpen: visibleCount > 0)
                // A separate task, so wakeHeartbeat() can end the sleep early.
                let sleep = Task { _ = try? await Task.sleep(for: interval, tolerance: interval / 2) }
                tickSleep = sleep
                await sleep.value
                await tick()
            }
        }
    }

    /// Any profile starting, stopping, appearing or going away changes the
    /// watched folders, so no frequent `colima list` is needed.
    private func makeDirWatcher() -> ColimaDirWatcher {
        ColimaDirWatcher(root: Paths.colimaDir, lima: Paths.limaDir) { [weak self] in
            Task { await self?.refreshStatus() }
        }
    }

    /// Ends the heartbeat's current sleep, so a tick runs now and the next
    /// sleep uses the interval for the new state.
    private func wakeHeartbeat() {
        tickSleep?.cancel()
    }

    /// Writes only the lists that changed, so views that read the others
    /// don't redraw.
    private func updateDerivedLists() {
        let d = Self.derivedLists(containers)
        if d.running != running { running = d.running }
        if d.stopped != stopped { stopped = d.stopped }
        if d.unhealthy != unhealthyCount { unhealthyCount = d.unhealthy }
    }

    /// Called on quit: the stable socket becomes a symlink to Colima's, so
    /// docker clients keep working without ColimaBar.
    func shutdown() {
        proxy.stop()
        if !isDebug { profileProxies.shutdown() }
    }

    /// Heartbeat (see tickInterval). Cheap work only: a stat() of the busy
    /// marker, publishing the stat streams' latest numbers, and a socket
    /// /_ping every 3 s (dashboard open) or 10 s (closed).
    private func tick() async {
        // A new Colima folder (for example ~/.colima made by a colima call
        // in a terminal) moves every socket: refresh at once.
        if Paths.colimaFoldersMoved { await refreshStatus() }
        let b = readBusy()
        if b != busy {
            let finished = busy != nil && b == nil
            busy = b
            if finished { await refreshAll() }
        }
        if visibleCount > 0 { publishStats() }

        let staleAfter = Self.staleAfter(state: state)
        // A containerd profile has no docker socket, so a ping says nothing
        // about it. Refresh its state only when it is stale.
        if !hasDockerSocket {
            if Date().timeIntervalSince(lastColima) > staleAfter { await refreshStatus() }
        } else if Date().timeIntervalSince(lastPing) >= (visibleCount > 0 ? 3 : 10) - 0.5 {
            // The 0.5 s margin absorbs the sleep's tolerance.
            lastPing = Date()
            let ping = await api.get("/_ping", timeout: 2)
            let up = ping?.ok ?? false
            if let v = ping?.headers["api-version"], v != proxy.apiVersion {
                proxy.apiVersion = v
                profileProxies.apiVersion = v
                profileProxies.setAPIVersion(v, for: profile)
                Defaults.set(v, .apiVersion)
            }
            let stale = Date().timeIntervalSince(lastColima) > staleAfter
            if up != (state == .running) || stale {
                await refreshStatus()
            } else if up, events == nil {
                startEvents()
            }
        }
        checkIdle()
        checkOtherProfilesIdle()
    }

    /// False when the profile's runtime is known and isn't docker (e.g.
    /// containerd): then no docker socket answers, so ColimaBar doesn't ping
    /// it, stream its events or list its containers.
    private var hasDockerSocket: Bool { Self.hasDockerSocket(runtime: vm.runtime) }

    /// The selected profile's busy marker, or the label of an action this app
    /// just launched whose script hasn't written its marker yet.
    private func readBusy() -> String? {
        Self.readBusyMarker(profile) ?? localBusy
    }

    /// The busy marker of any profile, or an action this app runs for it.
    private func readBusy(_ p: String) -> String? {
        p == profile ? readBusy() : Self.readBusyMarker(p) ?? profileActions[p]
    }

    /// The busy marker colima-ctl.sh writes while a long action runs. One left
    /// behind by a killed script is ignored after `staleBusyMarkerAge`.
    nonisolated private static func readBusyMarker(_ profile: String) -> String? {
        let path = Paths.busy(profile)
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
            let mtime = attrs[.modificationDate] as? Date
        else { return nil }
        if Date().timeIntervalSince(mtime) > staleBusyMarkerAge {
            try? FileManager.default.removeItem(atPath: path)
            return nil
        }
        return (try? String(contentsOfFile: path, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "Working"
    }

    // MARK: - Refresh

    /// `urgentDF`: a user action changed disk use, so df skips the 30 s gap.
    func refreshAll(urgentDF: Bool = false) async {
        await refreshStatus()
        if state == .running {
            await refreshContainers()
            requestDF(urgent: urgentDF)
        }
    }

    func refreshStatus() async {
        lastColima = Date()
        if Paths.refreshColimaFolders() { colimaFoldersChanged() }
        // Profiles and Lima instances come and go: watch the current set.
        dirWatcher?.rearm()
        guard Shell.which("colima") != nil else {
            set(\.state, .notInstalled)
            return
        }
        let gen = generation
        // The directory watcher and the heartbeat can both start a refresh.
        // An older `colima list` can end later; its result must not undo a
        // newer one (an old "Running" after a new "Stopped").
        let seq = statusOrder.begin()
        let r = await Shell.run(["colima", "list", "-j"], timeout: 10)
        guard gen == generation else { return }
        // A slow or failed `colima list` says nothing about the VM: keep the
        // current state instead of treating it as "stopped".
        guard r.ok else {
            log.error("colima list failed (status \(r.status)); keeping state")
            return
        }
        guard statusOrder.apply(seq) else { return }
        let dec = JSONDecoder()
        let all = r.out.split(separator: "\n").compactMap { try? dec.decode(ColimaListJSON.self, from: Data($0.utf8)) }
        // The selected profile was deleted (`colima delete -p X`): fall back
        // to default, so auto-start never provisions a fresh VM under the old
        // name. profile's didSet switches over and refreshes again.
        // A disk shrink deletes the profile for a short time while its busy
        // marker exists: keep the profile then.
        if profile != "default", readBusy() == nil, !all.isEmpty,
            !all.contains(where: { ($0.name ?? "default") == profile })
        {
            log.notice("profile \(self.profile, privacy: .public) no longer exists; switching to default")
            profile = "default"
            return
        }
        let wasRunningNames = Set(profiles.filter(\.isRunning).map(\.name))
        let hadProfiles = !profiles.isEmpty
        set(
            \.profiles,
            all.map {
                ProfileRow(
                    name: $0.name ?? "default", isRunning: $0.status == "Running", cpus: $0.cpus ?? 0,
                    memGB: Int(($0.memory ?? 0) / ByteFormat.bytesPerGiB), runtime: $0.runtime ?? "")
            })
        syncProfiles()
        // `colima start` of any profile switches the docker context to that
        // profile. The selected profile applies the routes below.
        if !isDebug, hadProfiles,
            profiles.contains(where: { $0.isRunning && $0.name != profile && !wasRunningNames.contains($0.name) })
        {
            Task { await Routing.apply() }
        }
        let info = all.first { ($0.name ?? "default") == profile }
        let newState: VMState = info?.status == "Running" ? .running : .stopped
        let wasRunning = state == .running

        if let info {
            var v = vm
            v.arch = info.arch ?? ""
            v.runtime = info.runtime ?? ""
            v.cpus = info.cpus ?? 0
            v.memGB = Int((info.memory ?? 0) / ByteFormat.bytesPerGiB)
            v.diskGB = Int((info.disk ?? 0) / ByteFormat.bytesPerGiB)
            if newState == .running && (!wasRunning || v.driver.isEmpty) {
                let s = await Shell.run(["colima", "status", "-j", "--profile", profile], timeout: 10)
                guard gen == generation, statusOrder.isLatestApplied(seq) else { return }
                if let st = try? dec.decode(ColimaStatusJSON.self, from: Data(s.out.utf8)) {
                    v.driver = st.driver ?? ""
                    v.mountType = st.mount_type ?? ""
                }
            }
            set(\.vm, v)
        }
        if let yaml = try? String(contentsOfFile: Paths.config(profile), encoding: .utf8) {
            set(\.isRosettaEnabled, Parse.yaml(yaml, key: "rosetta") == "true")
            set(\.isKubernetesEnabled, Parse.yaml(yaml, key: "enabled", section: "kubernetes") == "true")
        }
        if state != newState {
            log.notice("profile \(self.profile, privacy: .public): \(String(describing: newState), privacy: .public)")
        }
        set(\.state, newState)

        if newState == .running {
            if events == nil { startEvents() }
            if !wasRunning {
                revealIcon = false
                await refreshContainers()
                guard gen == generation else { return }
                requestDF()
                // `colima start` switches the docker context back to colima.
                if !isDebug {
                    Task {
                        await Routing.apply()
                        if visibleCount > 0, dashboardTab == .system { routing = await Routing.status() }
                    }
                }
            }
        } else {
            clearVMData()
        }
    }

    private func clearVMData() {
        events?.cancel()
        events = nil
        resetDF()
        syncStatStreams()
        set(\.containers, [])
        set(\.stats, [:])
        set(\.images, [])
        set(\.volumes, [])
        set(\.df, [])
        set(\.cpuHistory, [])
        set(\.memHistory, [])
    }

    private func switchProfile(from old: String) {
        // An action that this app runs keeps its label on its own profile, so
        // the profile menu shows it until the action ends (see execute).
        if let b = localBusy { profileActions[old] = b }
        localBusy = profileActions.removeValue(forKey: profile)
        // At once, not on the next tick: the Delete guard of the menu reads it.
        set(\.busy, readBusy())
        retargetSocket()
        syncWakeHolds()
        Task { await refreshAll() }
    }

    /// Points the API client, the saved logs and the stable proxy at the
    /// socket of the selected profile, and forgets the data of the old socket.
    private func retargetSocket() {
        generation += 1
        clearVMData()
        for h in statStreams.values { h.cancel() }
        statStreams = [:]
        latest = [:]
        api = DockerAPI(socketPath: Paths.socket(profile))
        keeper.reset(api: api)  // saved logs belong to the old socket
        // A stopped proxy links its path to the new upstream. A debug run
        // must not change the proxy sockets.
        if !isDebug { proxy.upstream = Paths.socket(profile) }
        vm = VMInfo()
        state = .unknown
        idleSince = nil
        otherIdle = [:]
    }

    /// The Colima folder changed (see Paths.refreshColimaFolders). Every
    /// socket, colima.yaml and watched folder moves with it.
    private func colimaFoldersChanged() {
        log.notice("the Colima folder is now \(Paths.colimaDir, privacy: .public)")
        retargetSocket()
        guard !isDebug else { return }
        profileProxies.refreshUpstreams()
        if dirWatcher != nil { dirWatcher = makeDirWatcher() }
    }

    /// True if the list was refreshed from the daemon.
    @discardableResult
    func refreshContainers() async -> Bool {
        guard hasDockerSocket else { return false }
        let gen = generation
        guard let r = await api.get("/containers/json?all=1"), r.ok, gen == generation, state == .running,
            let list = try? JSONDecoder().decode([APIContainer].self, from: r.body)
        else { return false }
        let mapped = list.map { c in
            Container(
                id: c.Id, name: c.Names.first.map { String($0.drop { $0 == "/" }) } ?? String(c.Id.prefix(12)),
                image: c.Image, state: c.State, status: c.Status,
                ports: Array(Set((c.Ports ?? []).compactMap { $0.IP != nil ? $0.PublicPort : nil })).sorted(),
                project: c.Labels?["com.docker.compose.project"])
        }
        // Stable order by name: rows never reorder because a number changed.
        set(\.containers, mapped.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending })
        syncStatStreams()
        return true
    }

    /// True while a dashboard shows a tab with `/system/df` data.
    private var wantsDF: Bool {
        visibleCount > 0 && Self.showsDiskUsage(dashboardTab) && state == .running && hasDockerSocket
    }

    /// Asks for fresh `/system/df` data. dockerd walks every volume and
    /// container layer for it, which can take seconds. So it runs only while
    /// a tab shows the data, one at a time, and at most once per 30 s (see
    /// DFGate). Requests in between join into one run.
    ///
    /// `urgent`: a user action (remove, prune, pull) changed disk use. The
    /// run skips the 30 s gap, so the Images and Volumes rows update at once.
    /// It still waits for a run in flight.
    func requestDF(urgent: Bool = false) {
        guard wantsDF else { return }
        scheduleDF(dfGate.request(now: Date(), urgent: urgent))
    }

    private func scheduleDF(_ step: DFGate.Step) {
        guard case .run(let wait) = step else { return }
        let gen = generation
        let token = dfToken
        let ticket = dfGate.ticket
        Task {
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            guard gen == generation, token == dfToken else { return }
            // An urgent request replaced this waiting run.
            guard ticket == dfGate.ticket else { return }
            // The tab may have closed during the wait.
            guard wantsDF else {
                dfGate.skip()
                return
            }
            dfGate.begin()
            diskDirty = false
            await refreshDF()
            guard gen == generation, token == dfToken else { return }
            scheduleDF(dfGate.end(now: Date()))
        }
    }

    /// Forgets the df schedule, for example when the VM stops.
    private func resetDF() {
        dfToken += 1
        dfGate = DFGate()
        diskDirty = false
    }

    private func refreshDF() async {
        let gen = generation
        guard let r = await api.get("/system/df", timeout: 30), r.ok, gen == generation,
            let d = try? JSONDecoder().decode(APIDF.self, from: r.body)
        else { return }
        let imgs = d.Images ?? []
        let ctrs = d.Containers ?? []
        let vols = d.Volumes ?? []
        let cache = d.BuildCache ?? []
        let unusedImg = imgs.filter { $0.Containers == 0 }
        let unusedVol = vols.filter { ($0.UsageData?.RefCount ?? 0) == 0 }
        func sum<T>(_ xs: [T], _ f: (T) -> Int64) -> Double { Double(xs.reduce(0) { $0 + max(f($1), 0) }) }
        set(
            \.df,
            [
                DFRow(
                    type: "Images", count: imgs.count, size: sum(imgs) { $0.Size },
                    reclaimable: sum(unusedImg) { $0.Size - ($0.SharedSize ?? 0) }),
                DFRow(
                    type: "Containers", count: ctrs.count, size: sum(ctrs) { $0.SizeRw ?? 0 },
                    reclaimable: sum(ctrs.filter { $0.State != "running" }) { $0.SizeRw ?? 0 }),
                DFRow(
                    type: "Volumes", count: vols.count, size: sum(vols) { $0.UsageData?.Size ?? 0 },
                    reclaimable: sum(unusedVol) { $0.UsageData?.Size ?? 0 }),
                DFRow(
                    type: "Build cache", count: cache.count, size: sum(cache) { $0.Size },
                    reclaimable: sum(cache.filter { !$0.InUse && !$0.Shared }) { $0.Size }),
            ])
        set(
            \.images,
            imgs.flatMap { i -> [ImageRow] in
                let tags = (i.RepoTags ?? []).filter { $0 != "<none>:<none>" }
                let created = Date(timeIntervalSince1970: TimeInterval(i.Created))
                if tags.isEmpty {
                    return [
                        ImageRow(
                            id: i.Id, repo: "<none>", tag: "<none>", size: Double(i.Size),
                            created: created, containers: i.Containers)
                    ]
                }
                return tags.map { t in
                    let colon = t.lastIndex(of: ":") ?? t.endIndex
                    return ImageRow(
                        id: i.Id + t, repo: String(t[..<colon]),
                        tag: colon < t.endIndex ? String(t[t.index(after: colon)...]) : "",
                        size: Double(i.Size), created: created, containers: i.Containers)
                }
            }.sorted { $0.size > $1.size })
        set(
            \.volumes,
            vols.map {
                VolumeRow(
                    name: $0.Name, size: Double($0.UsageData?.Size ?? 0), links: $0.UsageData?.RefCount ?? 0,
                    project: $0.Labels?["com.docker.compose.project"],
                    isAnonymous: $0.Labels?["com.docker.volume.anonymous"] != nil)
            }.sorted { ($0.links, $0.size) > ($1.links, $1.size) })
    }

    func refreshRouting() async {
        routing = await Routing.status()
    }

    // MARK: - Auto-start / auto-stop

    /// Called by a proxy when a docker request arrives while the VM is down:
    /// start it and return once Docker is really ready. `profile` is the
    /// profile of a profile socket; nil means the selected profile (the
    /// stable socket). Two calls for the same profile share one wake.
    func wakeForProxy(profile target: String? = nil) async -> Bool {
        let p = target ?? profile
        if let running = wakes[p] { return await running.task.value }
        wakeToken += 1
        let token = wakeToken
        let task = Task { await performWake(p) }
        wakes[p] = (token, task)
        syncWakeHolds()
        let ok = await task.value
        if wakes[p]?.token == token {
            wakes[p] = nil
            syncWakeHolds()
        }
        return ok
    }

    /// Holds each proxy whose upstream profile has a wake that runs now: the
    /// stable proxy for the selected profile, and the profile proxies. Their
    /// requests then wait for that wake, whichever proxy started it.
    private func syncWakeHolds() {
        let h = Self.holds(waking: Set(wakes.keys), selected: profile)
        proxy.holdForWake(h.stable)
        profileProxies.holdForWake(h.profiles)
    }

    /// The runtime of a profile: the live value for the selected profile,
    /// else the one from the last `colima list`. "" when unknown.
    private func runtime(of p: String) -> String {
        p == profile ? vm.runtime : profiles.first { $0.name == p }?.runtime ?? ""
    }

    /// "The socket accepts connections" is not ready: Lima's ssh tunnel opens
    /// it seconds before dockerd, and Colima's provisioning restarts dockerd
    /// and containerd a few times. A request in that window fails with
    /// "Unavailable: error reading from server: EOF". So this waits for
    /// `colima start` to exit, then for several successes in a row on an
    /// endpoint that goes through containerd.
    private func performWake(_ p: String) async -> Bool {
        let probe = DockerAPI(socketPath: Paths.socket(p))
        // GET /images/json is served by containerd's image store.
        let probePath =
            "/images/json?filters=" + DockerAPI.percentEncoded(#"{"reference":["colimabar-readiness-probe"]}"#)
        func ready() async -> Bool { await probe.get(probePath, timeout: 3)?.ok ?? false }

        if readBusy(p) == nil, await ready() { return true }
        // A deleted profile: `colima start` would provision a new VM. A disk
        // shrink deletes colima.yaml for a short time, so check again after
        // the wait for a running action.
        func profileMissing() -> Bool {
            if p != "default", !FileManager.default.fileExists(atPath: Paths.config(p)) {
                Notifier.shared.post("Profile \(p) doesn't exist, so it wasn't started.")
                return true
            }
            return false
        }
        if readBusy(p) == nil, profileMissing() { return false }
        // Only the docker runtime has a docker socket to wait for.
        let rt = runtime(of: p)
        if !Self.hasDockerSocket(runtime: rt) {
            log.notice("profile \(p, privacy: .public) uses the \(rt, privacy: .public) runtime; not auto-starting")
            return false
        }
        func startInFlight() async -> Bool {
            if readBusy(p) != nil { return true }
            return await Task.detached { Self.colimaStartRunning(p) }.value
        }
        // A start/stop is already running (menu, auto-stop, a terminal): let it
        // finish instead of racing it.
        for _ in 0..<Self.startWaitSeconds {
            guard await startInFlight() else { break }
            try? await Task.sleep(for: .seconds(1))
        }
        if !(await ready()) {
            if profileMissing() { return false }
            log.notice("auto-starting profile \(p, privacy: .public)")
            if p == profile { setBusyNow("Starting") } else { profileActions[p] = "Starting" }
            let r = await Shell.run(
                [Paths.ctl, CtlAction.start.rawValue], timeout: 600,
                extraEnv: ["COLIMABAR_PROFILE": p, "COLIMABAR_APP": "1"])
            // The selected profile can change during the start.
            if p == profile, localBusy == "Starting" { localBusy = nil }
            if profileActions[p] == "Starting" { profileActions[p] = nil }
            if !r.ok { log.error("auto-start: colima-ctl.sh start exited \(r.status) for \(p, privacy: .public)") }
        }
        var streak = 0
        let deadline = Date().addingTimeInterval(Self.readinessTimeout)
        while Date() < deadline {
            streak = await ready() ? streak + 1 : 0
            if streak >= Self.readinessStreak {
                // Refresh the cached API version from the real daemon (a Colima
                // update can change it) before more pings are answered locally.
                if let v = await probe.get("/_ping", timeout: 3)?.headers["api-version"] {
                    profileProxies.setAPIVersion(v, for: p)
                    if p == profile {
                        proxy.apiVersion = v
                        profileProxies.apiVersion = v
                        Defaults.set(v, .apiVersion)
                    }
                }
                Task { await refreshAll() }
                return true
            }
            try? await Task.sleep(for: Self.readinessInterval)
        }
        Notifier.shared.post("Colima profile \(p) didn't become ready. Check the Colima log.")
        return false
    }

    /// Makes one proxy and one `colimabar-PROFILE` context for each docker
    /// profile of the last `colima list`, and removes the ones of profiles
    /// that are gone. A debug run changes nothing. An empty list changes
    /// nothing either: it can come from a broken Colima install.
    private func syncProfiles() {
        guard !isDebug, !profiles.isEmpty else { return }
        let wanted = Set(
            profiles.filter { Self.hasDockerSocket(runtime: $0.runtime) && ProfileName.isValid($0.name) }.map(\.name))
        // A VM action can delete a profile for a short time (disk shrink):
        // keep its proxy until the action ends.
        let keep = profileProxies.names.filter { readBusy($0) != nil }
        profileProxies.sync(wanted: wanted, keep: keep)
        var hosts: [String: String] = [:]
        for p in profileProxies.names {
            if let path = profileProxies.path(for: p) { hosts[p] = "unix://\(path)" }
        }
        applyContexts(hosts)
    }

    /// Applies the `colimabar-PROFILE` contexts in the background, one run at
    /// a time. A run applies the newest wanted set. After a failure, the same
    /// set runs again only after `contextsRetryInterval`.
    private func applyContexts(_ hosts: [String: String]) {
        if let f = contextsFailure,
            !Self.contextsRetryDue(wanted: hosts, failed: f.wanted, failedAt: f.at, now: Date())
        {
            return
        }
        wantedContexts = hosts
        guard !isApplyingContexts else { return }
        isApplyingContexts = true
        Task {
            while let want = wantedContexts, want != appliedContexts {
                wantedContexts = nil
                guard await ProfileContexts.apply(wanted: want) else {
                    contextsFailure = (want, Date())
                    break
                }
                contextsFailure = nil
                appliedContexts = want
            }
            isApplyingContexts = false
        }
    }

    /// Stops the VM once it has had no running containers for the chosen time.
    /// Builds, pulls and pushes show no running container, so live docker
    /// traffic through the proxies also counts as "not idle". Transfers count
    /// on the stable socket and on the socket of the selected profile.
    private func checkIdle() {
        let check = AutoStopRule.evaluate(
            enabled: autoStop, isRunning: state == .running,
            isBusy: Self.blocksAutoStop(busyMarker: busy, actionsInFlight: actionsInFlight[profile] ?? 0)
                || isConfirmingAutoStop,
            runningContainers: running.count, transfers: selectedTransfers(), idleSince: idleSince, now: Date(),
            idleMinutes: autoStopMinutes)
        if check.idleSince != idleSince { idleSince = check.idleSince }
        guard check.isDue else { return }
        // The list can be stale (events missed during a reconnect): confirm
        // with a fresh one right before stopping.
        isConfirmingAutoStop = true
        let gen = generation
        Task {
            defer { isConfirmingAutoStop = false }
            // No fresh list (timeout, error): don't stop on stale data.
            let fresh = await refreshContainers()
            guard fresh, gen == generation, autoStop, state == .running, busy == nil,
                running.isEmpty, selectedTransfers() == 0
            else {
                idleSince = nil
                return
            }
            idleSince = nil
            log.notice("auto-stopping idle profile \(self.profile, privacy: .public)")
            run(.autoStop, "\(autoStopMinutes)")
        }
    }

    private func selectedTransfers() -> Int {
        proxy.activeTransfers() + profileProxies.activeTransfers(profile)
    }

    /// The auto-stop state of a running profile other than the selected one.
    private struct OtherIdle {
        var since: Date?
        var lastCheck: Date?
        var isChecking = false
    }

    /// Auto-stop for each running docker profile other than the selected
    /// one, with the same rules and timeout. Work through the profile's proxy
    /// resets its idle time at each tick. Each `AutoStopRule.otherCheckInterval`,
    /// a fresh container list from the profile's own socket counts its
    /// running containers. A failed list does not count as idle.
    private func checkOtherProfilesIdle() {
        guard autoStop, !isDebug else {
            if !otherIdle.isEmpty { otherIdle = [:] }
            return
        }
        let names = AutoStopRule.otherProfiles(profiles, selected: profile)
        for p in otherIdle.keys where !names.contains(p) { otherIdle[p] = nil }
        let now = Date()
        for p in names {
            var s = otherIdle[p] ?? OtherIdle()
            guard !s.isChecking else { continue }
            if profileProxies.activeTransfers(p, now: now) > 0 || readBusy(p) != nil {
                s.since = nil
                otherIdle[p] = s
                continue
            }
            guard AutoStopRule.isCheckDue(lastCheck: s.lastCheck, now: now) else { continue }
            s.isChecking = true
            s.lastCheck = now
            otherIdle[p] = s
            let gen = generation
            let api = DockerAPI(socketPath: Paths.socket(p))
            Task {
                let count = await Self.runningContainerCount(api)
                // A profile switch or a settings change reset the state.
                guard gen == generation, var s = otherIdle[p] else { return }
                s.isChecking = false
                let check = AutoStopRule.evaluate(
                    enabled: autoStop, isRunning: profiles.contains { $0.name == p && $0.isRunning } && p != profile,
                    isBusy: Self.blocksAutoStop(busyMarker: readBusy(p), actionsInFlight: actionsInFlight[p] ?? 0),
                    runningContainers: count, transfers: profileProxies.activeTransfers(p),
                    idleSince: s.since, now: Date(), idleMinutes: autoStopMinutes)
                s.since = check.idleSince
                otherIdle[p] = check.isDue ? nil : s
                guard check.isDue else { return }
                log.notice("auto-stopping idle profile \(p, privacy: .public)")
                run(.autoStop, "\(autoStopMinutes)", profile: p)
            }
        }
    }

    /// The number of running containers on a profile's socket, or nil if
    /// the request failed.
    nonisolated private static func runningContainerCount(_ api: DockerAPI) async -> Int? {
        guard let r = await api.get("/containers/json", timeout: 5), r.ok,
            let list = try? JSONDecoder().decode([APIContainer].self, from: r.body)
        else { return nil }
        return list.count
    }

    // MARK: - Live stats

    /// Only what the open tab needs: `colima list` when the last one is over
    /// a minute old, df for the disk tabs, and routing for the System tab.
    private func becameVisible() {
        Task {
            if Date().timeIntervalSince(lastColima) >= Self.statusMaxAgeOnOpen { await refreshStatus() }
            if state == .running {
                await refreshContainers()
                requestDF(urgent: diskDirty)
            }
            if dashboardTab == .system { routing = await Routing.status() }
        }
        syncStatStreams()
    }

    /// One `stats?stream=1` connection per running container while visible;
    /// the daemon pushes a sample each second with the previous one included,
    /// so CPU% needs no polling or bookkeeping on our side.
    private func syncStatStreams() {
        let want = visibleCount > 0 && state == .running ? Set(running.map(\.id)) : []
        for (id, h) in statStreams where !want.contains(id) {
            h.cancel()
            statStreams[id] = nil
            latest[id] = nil
        }
        let gen = generation
        for id in want where statStreams[id] == nil {
            statStreams[id] = api.stream(
                "/containers/\(id)/stats?stream=1",
                onLine: { [weak self] line in
                    guard let s = try? JSONDecoder().decode(APIStats.self, from: line) else { return }
                    let stat = Stat(cpu: s.cpuPercent, memBytes: s.memBytes)
                    Task { @MainActor in
                        guard let self, self.generation == gen else { return }
                        self.latest[id] = stat
                    }
                },
                onEnd: { [weak self] handle in
                    Task { @MainActor in
                        // Only clear the entry if it's still this stream, not a newer one.
                        guard let self, self.generation == gen, self.statStreams[id] === handle else { return }
                        self.statStreams[id] = nil
                        self.latest[id] = nil
                    }
                })
        }
        if want.isEmpty { set(\.stats, [:]) }
    }

    private func publishStats() {
        set(\.stats, latest)
        guard state == .running else { return }
        let cpu = latest.values.reduce(0) { $0 + $1.cpu } / Double(max(vm.cpus, 1))
        let vmBytes = Double(max(vm.memGB, 1)) * Double(ByteFormat.bytesPerGiB)
        let mem = latest.values.reduce(0) { $0 + $1.memBytes } / vmBytes * 100
        push(&cpuHistory, min(cpu, 100))
        push(&memHistory, min(mem, 100))
    }

    // MARK: - Events

    private func startEvents() {
        guard hasDockerSocket else { return }
        let filters = DockerAPI.percentEncoded(Self.eventFilter)
        let gen = generation
        events = api.stream(
            "/events?filters=\(filters)",
            onLine: { [weak self] line in
                guard let ev = try? JSONDecoder().decode(DockerEvent.self, from: line),
                    !Self.ignores(action: ev.Action ?? "")
                else { return }
                Task { @MainActor in
                    guard let self, self.generation == gen else { return }
                    self.handle(ev)
                }
            },
            onEnd: { [weak self] handle in
                // VM stopped or socket hiccup: the heartbeat's ping reconnects.
                Task { @MainActor in
                    guard let self, self.generation == gen, self.events === handle else { return }
                    self.events = nil
                }
            })
        // Events that happened while no stream was open are lost: reload the
        // list so a container started in that gap isn't missed.
        Task { await refreshContainers() }
    }

    private func handle(_ ev: DockerEvent) {
        let attrs = ev.Actor?.Attributes ?? [:]
        let action = ev.Action ?? ""
        // Stats/exec events fire constantly and change nothing we show.
        if Self.ignores(action: action) { return }
        // testcontainers' containers are torn down (often non-zero) on every
        // test run; their failures already show up in the test output.
        let isTestcontainer = attrs["org.testcontainers"] == "true"
        if notifyOnCrash, ev.Type == "container", !isTestcontainer, let id = ev.Actor?.ID {
            let name = attrs["name"] ?? "container"
            let ctr = ContainerRef(id: id, name: name)
            if action == "oom" {
                Notifier.shared.post("Killed: out of memory", title: name, container: ctr, profile: profile)
            } else if action == "die", let code = attrs["exitCode"], Self.isCrashExit(code) {
                Notifier.shared.post("Exited with code \(code)", title: name, container: ctr, profile: profile)
            } else if action == "health_status: unhealthy" {
                Notifier.shared.post("Healthcheck is failing", title: name, container: ctr, profile: profile)
            }
        }
        let reaction = Self.reaction(type: ev.Type ?? "", action: action)
        if reaction.contains(.savedLogs), let id = ev.Actor?.ID {
            keeper.event(action: action, id: id, attributes: attrs)
        }
        if reaction.contains(.disk) { diskDirty = true }
        guard !reaction.isEmpty else { return }
        if reaction.contains(.containers) { reloadPending = true }
        // Coalesce a burst of events (compose up/down) into one refresh.
        containerRefresh?.cancel()
        containerRefresh = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            if reloadPending {
                reloadPending = false
                await refreshContainers()
            }
            if diskDirty { requestDF() }
        }
    }

    // MARK: - Actions

    /// Runs a colima-ctl.sh action (it owns confirm dialogs, config edits,
    /// the busy marker and notifications), then refreshes. `profile` is the
    /// profile to act on; nil means the selected profile.
    func run(_ action: CtlAction, _ args: String..., profile target: String? = nil) {
        let p = target ?? profile
        if action.showsDialog { dismissPopover() }
        let label = markBusy(action, p)
        Task { await execute(action, args, profile: p, label: label) }
    }

    /// Shows the busy label at once, not on the next tick, so a second click
    /// can't race the action. The selected profile shows it in the header,
    /// another profile in the profile menu.
    private func markBusy(_ action: CtlAction, _ p: String) -> String? {
        guard let label = action.busyLabel else { return nil }
        if p == profile { setBusyNow(label) } else { profileActions[p] = label }
        return label
    }

    /// Returns true if the script exited with 0.
    @discardableResult
    private func execute(_ action: CtlAction, _ args: [String], profile p: String, label: String?) async -> Bool {
        actionsInFlight[p, default: 0] += 1
        defer { actionsInFlight[p, default: 1] -= 1 }
        let r = await Shell.run(
            [Paths.ctl, action.rawValue] + args, timeout: 900,
            extraEnv: ["COLIMABAR_PROFILE": p, "COLIMABAR_APP": "1"])
        // colima-ctl.sh reports failures as "COLIMABAR_NOTIFY:<message>"
        // lines when ColimaBar runs it, so they arrive as native alerts.
        var notified = false
        for line in r.out.split(separator: "\n") where line.hasPrefix("COLIMABAR_NOTIFY:") {
            Notifier.shared.post(String(line.dropFirst("COLIMABAR_NOTIFY:".count)))
            notified = true
        }
        // Exit 2 = the user cancelled a confirm dialog or another action holds the lock.
        if !r.ok, !notified, r.status != 2 {
            Notifier.shared.post(
                "\(action.rawValue) failed for profile \(p) (exit \(r.status)). See \(Paths.ctlLog).")
        }
        // The action is over (done, failed or cancelled): drop the
        // placeholder, but only if a newer action hasn't replaced it.
        if p == profile, localBusy == label { localBusy = nil }
        if let label, profileActions[p] == label { profileActions[p] = nil }
        busy = readBusy()
        await refreshAll(urgentDF: action.changesDisk)
        return r.ok
    }

    // MARK: - Profiles

    /// Starts the VM of a profile that is not selected.
    func startProfile(_ p: String) { run(.start, profile: p) }

    /// Stops the VM of a profile that is not selected.
    func stopProfile(_ p: String) { run(.stop, profile: p) }

    /// Creates a profile and starts its VM. The directory watcher then
    /// lists it, and it gets its proxy and its docker context.
    func createProfile(_ form: NewProfileForm) {
        if let problem = form.problem(existing: profiles.map(\.name)) {
            Notifier.shared.post(problem)
            return
        }
        let label = markBusy(.profileCreate, form.name)
        Task { await execute(.profileCreate, form.arguments, profile: form.name, label: label) }
    }

    /// True while the VM of the profile runs. Right after a switch, the
    /// state of the selected profile is unknown: then the last `colima list`
    /// decides, and a profile that it does not show counts as running.
    func isRunning(profile p: String) -> Bool {
        let row = profiles.first { $0.name == p }
        guard p == profile else { return row?.isRunning ?? false }
        return Self.selectedIsRunning(state: state, listed: row?.isRunning)
    }

    /// Deletes a profile with its VM and data. A running selected profile
    /// must stop first. After the delete, its proxy socket and its
    /// `colimabar-PROFILE` context go away. If it was selected, the
    /// dashboard switches to `default`.
    func deleteProfile(_ p: String) {
        // An action of the profile can start while the confirmation is open.
        if readBusy(p) != nil || profileActions[p] != nil || (p == profile && busy != nil) {
            Notifier.shared.post("Wait until the action of the profile \(p) ends, then delete it.")
            return
        }
        if let refusal = ProfileDelete.refusal(profile: p, selected: profile, isRunning: isRunning(profile: p)) {
            Notifier.shared.post(refusal)
            return
        }
        let label = markBusy(.profileDelete, p)
        Task {
            guard await execute(.profileDelete, [], profile: p, label: label) else { return }
            if !isDebug {
                profileProxies.remove(p)
                appliedContexts?[p] = nil
                await ProfileContexts.remove(profile: p)
            }
            let next = ProfileDelete.nextSelection(deleted: p, selected: profile, remaining: profiles.map(\.name))
            if next != profile { profile = next }
        }
    }

    private func setBusyNow(_ label: String) {
        localBusy = label
        if busy == nil { busy = label }
    }

    func record(_ title: String, _ body: String, containerID: String?) {
        alerts.insert(AlertItem(title: title, body: body, containerID: containerID), at: 0)
        if alerts.count > Self.alertCap { alerts.removeLast(alerts.count - Self.alertCap) }
    }

    func clearAlerts() {
        alerts.removeAll()
    }

    func container(withID id: String) -> Container? { containers.first { $0.id == id } }

    /// Client for a profile's socket: the live one for the selected profile.
    private func api(for p: String) -> DockerAPI {
        p == profile ? api : DockerAPI(socketPath: Paths.socket(p))
    }

    /// Container lifecycle calls that need no confirmation go straight to the API.
    /// The timeout covers containers with a long stop grace period.
    func container(_ id: String, _ verb: ContainerVerb, profile p: String? = nil) {
        let client = api(for: p ?? profile)
        Task {
            let r = await client.post("/containers/\(id)/\(verb.rawValue)", timeout: verb == .start ? 60 : 180)
            if !(r?.ok ?? false) {
                let msg = r.flatMap { try? JSONDecoder().decode([String: String].self, from: $0.body)["message"] }
                Notifier.shared.post("\(verb.rawValue.capitalized) failed: \(msg ?? "no response from Docker")")
            }
            await refreshContainers()
        }
    }

    /// stop|start|restart every container of a compose project. At most
    /// `projectConcurrency` requests run at once: each one holds a thread
    /// for up to 180 s.
    func project(_ name: String, _ verb: ContainerVerb) {
        let ids = containers.filter {
            $0.project == name && (verb == .start ? !$0.isRunning : $0.isRunning || verb == .restart)
        }
        .map(\.id)
        let names = Dictionary(uniqueKeysWithValues: containers.map { ($0.id, $0.name) })
        Task { [api] in
            let failed = await Self.failures(ids, limit: Self.projectConcurrency) { id in
                let r = await api.post("/containers/\(id)/\(verb.rawValue)", timeout: 180)
                return (r?.ok ?? false) ? nil : names[id] ?? String(id.prefix(12))
            }
            if !failed.isEmpty {
                Notifier.shared.post(
                    "\(verb.rawValue.capitalized) failed for \(failed.sorted().joined(separator: ", ")).")
            }
            await refreshContainers()
        }
    }

    /// Opens the log window. If the container is gone and `keeper` saved
    /// its last lines, the window shows them instead of live logs.
    func openLogs(id: String, name: String, profile p: String? = nil) {
        let target = p ?? profile
        let keeper = self.keeper
        let saved: (@MainActor () -> [LogLine]?)? =
            target == profile ? { @MainActor [weak keeper] in keeper?.saved(id) } : nil
        LogWindows.shared.open(api: api(for: target), id: id, name: name, savedLines: saved) { [weak self] in
            self?.terminal(.containerLogs, name, profile: target)
        }
    }

    /// Runs a colima-ctl.sh action in a terminal window.
    func terminal(_ action: CtlAction, _ args: String..., profile p: String? = nil) {
        let words = [Paths.ctl, action.rawValue] + args
        // The same Colima folder as the app, also when the shell sets COLIMA_HOME.
        Shell.inTerminal(
            "COLIMA_HOME=\(Shell.quote(Paths.preparedColimaDir())) COLIMABAR_PROFILE=\(Shell.quote(p ?? profile)) "
                + words.map(Shell.quote).joined(separator: " "))
    }

    func open(port: Int) {
        if let u = URL(string: "http://localhost:\(port)") { NSWorkspace.shared.open(u) }
    }

    func notify(_ msg: String) { Notifier.shared.post(msg) }

    // MARK: - Helpers

    private func set<T: Equatable>(_ kp: ReferenceWritableKeyPath<ColimaModel, T>, _ v: T) {
        if self[keyPath: kp] != v { self[keyPath: kp] = v }
    }

    private func push(_ arr: inout [Double], _ v: Double) {
        arr.append(v)
        if arr.count > historyLen { arr.removeFirst(arr.count - historyLen) }
    }
}
