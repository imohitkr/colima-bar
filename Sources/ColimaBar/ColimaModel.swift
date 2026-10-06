import AppKit
import Foundation
import Observation
import os

enum VMState: Equatable { case unknown, running, stopped, notInstalled }

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
    var state: VMState = .unknown {
        didSet { if state != oldValue { wakeHeartbeat() } }
    }
    var busy: String?
    var vm = VMInfo()
    var rosetta = false
    var k8s = false
    var containers: [Container] = [] {
        didSet { updateDerivedLists() }
    }
    var stats: [String: Stat] = [:]     // by container id
    var cpuHistory: [Double] = []       // % of VM CPU used by containers
    var memHistory: [Double] = []       // % of VM memory used by containers
    var df: [DFRow] = []
    var images: [ImageRow] = []
    var volumes: [VolumeRow] = []
    var profiles: [ProfileRow] = []
    var routing = Routing.Status()
    /// The dashboard's selected tab, set by DashboardView. No view reads it
    /// here; it tells the model which costly data is on screen.
    @ObservationIgnored var dashboardTab: Tab = .containers {
        didSet {
            guard dashboardTab != oldValue, visibleCount > 0 else { return }
            if Self.showsDiskUsage(dashboardTab) { requestDF() }
            if dashboardTab == .system { Task { await refreshRouting() } }
        }
    }
    var alerts: [AlertItem] = []            // newest first, also shown in the dashboard
    var notificationsAllowed = true
    var idleSince: Date?

    var profile = Defaults.string("profile") ?? "default" {
        didSet {
            guard profile != oldValue else { return }
            Defaults.set(profile, "profile")
            switchProfile()
        }
    }
    var notifyOnCrash = Defaults.bool("notifyOnCrash") ?? true {
        didSet { Defaults.set(notifyOnCrash, "notifyOnCrash") }
    }
    var autoStart = Defaults.bool("autoStart") ?? true {
        didSet {
            guard autoStart != oldValue else { return }
            Defaults.set(autoStart, "autoStart")
            autoStart ? proxy.start() : proxy.stop()
        }
    }
    var autoStop = Defaults.bool("autoStop") ?? false {
        didSet { Defaults.set(autoStop, "autoStop"); idleSince = nil }
    }
    var autoStopMinutes = Defaults.int("autoStopMinutes").map { min(max($0, 1), 1440) } ?? 30 {
        didSet {
            let v = min(max(autoStopMinutes, IdleMinutes.range.lowerBound), IdleMinutes.range.upperBound)
            if v != autoStopMinutes { autoStopMinutes = v; return }
            Defaults.set(autoStopMinutes, "autoStopMinutes")
            idleSince = nil
        }
    }
    var hideIconWhenStopped = Defaults.bool("hideIconWhenStopped") ?? false {
        didSet { Defaults.set(hideIconWhenStopped, "hideIconWhenStopped") }
    }
    /// Set when the app is reopened from Spotlight/Finder while its icon is
    /// hidden. It keeps the icon visible until the dashboard opens. When the
    /// last dashboard surface closes, or the VM starts, it clears, so the icon
    /// hides again if Colima is still stopped.
    var revealIcon = false

    /// Only the menu bar icon hides; the process, the auto-start proxy and the
    /// light heartbeat keep running so `docker` still wakes the VM.
    var iconHidden: Bool {
        Self.hidesIcon(enabled: hideIconWhenStopped, revealed: revealIcon, state: state,
                       busy: busy != nil, dashboardOpen: visibleCount > 0,
                       otherProfileRunning: profiles.contains { $0.running && $0.name != profile })
    }

    /// The icon hides only when the VM is known to be stopped, nothing is in
    /// progress and no other profile's VM runs. Unknown and not-installed
    /// states keep it visible.
    nonisolated static func hidesIcon(enabled: Bool, revealed: Bool, state: VMState, busy: Bool,
                                      dashboardOpen: Bool, otherProfileRunning: Bool = false) -> Bool {
        enabled && !revealed && state == .stopped && !busy && !dashboardOpen && !otherProfileRunning
    }

    /// The first time the icon ever hides, say where it went and how to get it
    /// back. Only once per user, not once per hide or per launch.
    func noteIconHiddenOnce() {
        // Another instance (during a launch handover) may have just set the
        // flag: re-read it from disk, and claim it atomically with a file.
        CFPreferencesAppSynchronize(kCFPreferencesCurrentApplication)
        guard !Defaults.bool("toldIconHidden").orFalse else { return }
        let marker = "\(Paths.cacheDir)/told-icon-hidden"
        let fd = Darwin.open(marker, O_CREAT | O_EXCL | O_WRONLY, 0o600)
        Defaults.set(true, "toldIconHidden")
        guard fd >= 0 else { return }   // someone else claimed it first
        close(fd)
        Notifier.shared.post("The icon is hidden while Colima is stopped. It comes back when Colima starts. To show it now, open ColimaBar from Spotlight.",
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
    private let log = Logger(subsystem: "com.imohitkr.ColimaBar", category: "model")
    // Internal bookkeeping that no view reads: writes skip observation.
    @ObservationIgnored private var events: StreamHandle?
    @ObservationIgnored private var statStreams: [String: StreamHandle] = [:]
    @ObservationIgnored private var latest: [String: Stat] = [:]   // written by stat streams, published once a second
    @ObservationIgnored private var tickTask: Task<Void, Never>?
    @ObservationIgnored private var tickSleep: Task<Void, Never>?  // the heartbeat's current sleep
    @ObservationIgnored private var containerRefresh: Task<Void, Never>?
    @ObservationIgnored private var dfGate = DFGate()
    @ObservationIgnored private var dfToken = 0         // bumps when dfGate resets; older df tasks then stop
    @ObservationIgnored private var diskDirty = false   // an event changed images, volumes or disk use
    @ObservationIgnored private var lastColima = Date.distantPast
    @ObservationIgnored private var lastPing = Date()
    @ObservationIgnored private var dirWatcher: ColimaDirWatcher?
    @ObservationIgnored private var isDebug = false
    @ObservationIgnored private var generation = 0     // bumps on profile switch; stale callbacks are ignored
    @ObservationIgnored private var stopping = false   // an auto-stop check is confirming
    @ObservationIgnored private var localBusy: String? // VM action launched here, marker not written yet
    private let historyLen = 60

    init() {
        let p = Defaults.string("profile") ?? "default"
        api = DockerAPI(socketPath: Paths.socket(p))
        proxy = SocketProxy(upstream: Paths.socket(p))
        proxy.apiVersion = Defaults.string("apiVersion")
    }

    func start(debug: Bool = false) {
        isDebug = debug
        if !debug {
            proxy.wake = { [weak self] in await self?.wakeForProxy() ?? false }
            if autoStart { proxy.start() } else { proxy.stop() }
            Task {
                await Routing.apply()
                routing = await Routing.status()
            }
            // Any profile starting, stopping, appearing or going away changes
            // these directories, so no frequent `colima list` is needed.
            dirWatcher = ColimaDirWatcher { [weak self] in
                Task { await self?.refreshStatus() }
            }
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

    /// The heartbeat runs once a second while a dashboard is open or an
    /// action is in progress. Otherwise it runs every 5 seconds, also while
    /// the VM runs: auto-stop does not need finer steps, and opening the
    /// dashboard ends the current sleep at once.
    nonisolated static func tickInterval(state: VMState, busy: Bool, dashboardOpen: Bool) -> Duration {
        !busy && !dashboardOpen ? .seconds(5) : .seconds(1)
    }

    /// How old the last `colima list` can be before the heartbeat runs it
    /// again. The directory watcher and the socket ping catch state changes,
    /// so a running or stopped VM needs only a rare check.
    nonisolated static func staleAfter(state: VMState) -> TimeInterval {
        state == .stopped || state == .running ? 5 * 60 : 60
    }

    /// Opening the dashboard runs `colima list` only when the last one is at
    /// least this old.
    nonisolated static let statusMaxAgeOnOpen: TimeInterval = 60

    /// The Images, Volumes and System tabs show data from `/system/df`.
    nonisolated static func showsDiskUsage(_ tab: Tab) -> Bool { tab != .containers }

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

    nonisolated static func derivedLists(_ containers: [Container])
        -> (running: [Container], stopped: [Container], unhealthy: Int) {
        (containers.filter(\.isRunning), containers.filter { !$0.isRunning },
         containers.reduce(0) { $0 + ($1.health == "unhealthy" ? 1 : 0) })
    }

    /// Called on quit: the stable socket becomes a symlink to Colima's, so
    /// docker clients keep working without ColimaBar.
    func shutdown() {
        proxy.stop()
    }

    /// Heartbeat (see tickInterval). Cheap work only: a stat() of the busy
    /// marker, publishing the stat streams' latest numbers, and a socket
    /// /_ping every 3 s (dashboard open) or 10 s (closed).
    private func tick() async {
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
                Defaults.set(v, "apiVersion")
            }
            let stale = Date().timeIntervalSince(lastColima) > staleAfter
            if up != (state == .running) || stale {
                await refreshStatus()
            } else if up, events == nil {
                startEvents()
            }
        }
        checkIdle()
    }

    /// False when the profile's runtime is known and isn't docker (e.g.
    /// containerd): then no docker socket answers, so ColimaBar doesn't ping
    /// it, stream its events or list its containers.
    private var hasDockerSocket: Bool { Self.hasDockerSocket(runtime: vm.runtime) }

    nonisolated static func hasDockerSocket(runtime: String) -> Bool {
        runtime.isEmpty || runtime == "docker"
    }

    /// The selected profile's busy marker, or the label of an action this app
    /// just launched whose script hasn't written its marker yet.
    private func readBusy() -> String? {
        Self.readBusyMarker(profile) ?? localBusy
    }

    /// The busy marker colima-ctl.sh writes while a long action runs. One left
    /// behind by a killed script is ignored after 20 minutes.
    nonisolated private static func readBusyMarker(_ profile: String) -> String? {
        let path = Paths.busy(profile)
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let mtime = attrs[.modificationDate] as? Date else { return nil }
        if Date().timeIntervalSince(mtime) > 20 * 60 {
            try? FileManager.default.removeItem(atPath: path)
            return nil
        }
        return (try? String(contentsOfFile: path, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "Working"
    }

    // MARK: - Refresh

    func refreshAll() async {
        await refreshStatus()
        if state == .running {
            await refreshContainers()
            requestDF()
        }
    }

    func refreshStatus() async {
        lastColima = Date()
        // Profiles and Lima instances come and go: watch the current set.
        dirWatcher?.rearm()
        guard Shell.which("colima") != nil else {
            set(\.state, .notInstalled)
            return
        }
        let gen = generation
        let r = await Shell.run(["colima", "list", "-j"], timeout: 10)
        guard gen == generation else { return }
        // A slow or failed `colima list` says nothing about the VM: keep the
        // current state instead of treating it as "stopped".
        guard r.ok else {
            log.error("colima list failed (status \(r.status)); keeping state")
            return
        }
        let dec = JSONDecoder()
        let all = r.out.split(separator: "\n").compactMap { try? dec.decode(ColimaListJSON.self, from: Data($0.utf8)) }
        // The selected profile was deleted (`colima delete -p X`): fall back
        // to default, so auto-start never provisions a fresh VM under the old
        // name. profile's didSet switches over and refreshes again.
        if profile != "default", !all.isEmpty, !all.contains(where: { ($0.name ?? "default") == profile }) {
            log.notice("profile \(self.profile, privacy: .public) no longer exists; switching to default")
            profile = "default"
            return
        }
        set(\.profiles, all.map {
            ProfileRow(name: $0.name ?? "default", running: $0.status == "Running", cpus: $0.cpus ?? 0,
                       memGB: Int(($0.memory ?? 0) / (1 << 30)))
        })
        let info = all.first { ($0.name ?? "default") == profile }
        let newState: VMState = info?.status == "Running" ? .running : .stopped
        let wasRunning = state == .running

        if let info {
            var v = vm
            v.arch = info.arch ?? ""
            v.runtime = info.runtime ?? ""
            v.cpus = info.cpus ?? 0
            v.memGB = Int((info.memory ?? 0) / (1 << 30))
            v.diskGB = Int((info.disk ?? 0) / (1 << 30))
            if newState == .running && (!wasRunning || v.driver.isEmpty) {
                let s = await Shell.run(["colima", "status", "-j", "--profile", profile], timeout: 10)
                guard gen == generation else { return }
                if let st = try? dec.decode(ColimaStatusJSON.self, from: Data(s.out.utf8)) {
                    v.driver = st.driver ?? ""
                    v.mountType = st.mount_type ?? ""
                }
            }
            set(\.vm, v)
        }
        if let yaml = try? String(contentsOfFile: Paths.config(profile), encoding: .utf8) {
            set(\.rosetta, Parse.yaml(yaml, key: "rosetta") == "true")
            set(\.k8s, Parse.yaml(yaml, key: "enabled", section: "kubernetes") == "true")
        }
        if state != newState { log.notice("profile \(self.profile, privacy: .public): \(String(describing: newState), privacy: .public)") }
        set(\.state, newState)

        if newState == .running {
            if events == nil { startEvents() }
            if !wasRunning {
                revealIcon = false
                await refreshContainers()
                guard gen == generation else { return }
                requestDF()
                // `colima start` switches the docker context back to colima.
                if !isDebug { Task {
                    await Routing.apply()
                    if visibleCount > 0, dashboardTab == .system { routing = await Routing.status() }
                } }
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

    private func switchProfile() {
        generation += 1
        localBusy = nil
        clearVMData()
        for h in statStreams.values { h.cancel() }
        statStreams = [:]
        latest = [:]
        api = DockerAPI(socketPath: Paths.socket(profile))
        proxy.upstream = Paths.socket(profile)
        vm = VMInfo()
        state = .unknown
        idleSince = nil
        Task { await refreshAll() }
    }

    /// True if the list was refreshed from the daemon.
    @discardableResult
    func refreshContainers() async -> Bool {
        guard hasDockerSocket else { return false }
        let gen = generation
        guard let r = await api.get("/containers/json?all=1"), r.ok, gen == generation, state == .running,
              let list = try? JSONDecoder().decode([APIContainer].self, from: r.body) else { return false }
        let mapped = list.map { c in
            Container(id: c.Id, name: c.Names.first.map { String($0.drop { $0 == "/" }) } ?? String(c.Id.prefix(12)),
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
    func requestDF() {
        guard wantsDF else { return }
        scheduleDF(dfGate.request(now: Date()))
    }

    private func scheduleDF(_ step: DFGate.Step) {
        guard case .run(let wait) = step else { return }
        let gen = generation
        let token = dfToken
        Task {
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            guard gen == generation, token == dfToken else { return }
            // The tab may have closed during the wait.
            guard wantsDF else { dfGate.skip(); return }
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
              let d = try? JSONDecoder().decode(APIDF.self, from: r.body) else { return }
        let imgs = d.Images ?? []
        let ctrs = d.Containers ?? []
        let vols = d.Volumes ?? []
        let cache = d.BuildCache ?? []
        let unusedImg = imgs.filter { $0.Containers == 0 }
        let unusedVol = vols.filter { ($0.UsageData?.RefCount ?? 0) == 0 }
        func sum<T>(_ xs: [T], _ f: (T) -> Int64) -> Double { Double(xs.reduce(0) { $0 + max(f($1), 0) }) }
        set(\.df, [
            DFRow(type: "Images", count: imgs.count, size: sum(imgs) { $0.Size },
                  reclaimable: sum(unusedImg) { $0.Size - ($0.SharedSize ?? 0) }),
            DFRow(type: "Containers", count: ctrs.count, size: sum(ctrs) { $0.SizeRw ?? 0 },
                  reclaimable: sum(ctrs.filter { $0.State != "running" }) { $0.SizeRw ?? 0 }),
            DFRow(type: "Volumes", count: vols.count, size: sum(vols) { $0.UsageData?.Size ?? 0 },
                  reclaimable: sum(unusedVol) { $0.UsageData?.Size ?? 0 }),
            DFRow(type: "Build cache", count: cache.count, size: sum(cache) { $0.Size },
                  reclaimable: sum(cache.filter { !$0.InUse && !$0.Shared }) { $0.Size }),
        ])
        set(\.images, imgs.flatMap { i -> [ImageRow] in
            let tags = (i.RepoTags ?? []).filter { $0 != "<none>:<none>" }
            let created = Date(timeIntervalSince1970: TimeInterval(i.Created))
            if tags.isEmpty {
                return [ImageRow(id: i.Id, repo: "<none>", tag: "<none>", size: Double(i.Size),
                                 created: created, containers: i.Containers)]
            }
            return tags.map { t in
                let colon = t.lastIndex(of: ":") ?? t.endIndex
                return ImageRow(id: i.Id + t, repo: String(t[..<colon]),
                                tag: colon < t.endIndex ? String(t[t.index(after: colon)...]) : "",
                                size: Double(i.Size), created: created, containers: i.Containers)
            }
        }.sorted { $0.size > $1.size })
        set(\.volumes, vols.map {
            VolumeRow(name: $0.Name, size: Double($0.UsageData?.Size ?? 0), links: $0.UsageData?.RefCount ?? 0,
                      project: $0.Labels?["com.docker.compose.project"],
                      anonymous: $0.Labels?["com.docker.volume.anonymous"] != nil)
        }.sorted { ($0.links, $0.size) > ($1.links, $1.size) })
    }

    func refreshRouting() async {
        routing = await Routing.status()
    }

    // MARK: - Auto-start / auto-stop

    /// Called by the proxy when a docker request arrives while the VM is down:
    /// start it and return once Docker is really ready.
    ///
    /// "The socket accepts connections" is not ready: Lima's ssh tunnel opens
    /// it seconds before dockerd, and Colima's provisioning restarts dockerd
    /// and containerd a few times. A request in that window fails with
    /// "Unavailable: error reading from server: EOF". So this waits for
    /// `colima start` to exit, then for several successes in a row on an
    /// endpoint that goes through containerd.
    private func wakeForProxy() async -> Bool {
        let p = profile
        let probe = DockerAPI(socketPath: Paths.socket(p))
        // GET /images/json is served by containerd's image store.
        let probePath = "/images/json?filters=" + DockerAPI.q(#"{"reference":["colimabar-readiness-probe"]}"#)
        func ready() async -> Bool { await probe.get(probePath, timeout: 3)?.ok ?? false }

        if readBusy() == nil, await ready() { return true }
        // A deleted profile: `colima start` would provision a new VM.
        if p != "default", !FileManager.default.fileExists(atPath: Paths.config(p)) {
            Notifier.shared.post("Profile \(p) doesn't exist, so it wasn't started.")
            return false
        }
        // Only the docker runtime has a docker socket to wait for.
        if !hasDockerSocket {
            log.notice("profile \(p, privacy: .public) uses the \(self.vm.runtime, privacy: .public) runtime; not auto-starting")
            return false
        }
        func startInFlight() async -> Bool {
            if readBusy() != nil { return true }
            return await Task.detached { Self.colimaStartRunning(p) }.value
        }
        // A start/stop is already running (menu, auto-stop, a terminal): let it
        // finish instead of racing it.
        for _ in 0..<300 {
            guard await startInFlight() else { break }
            try? await Task.sleep(for: .seconds(1))
        }
        if !(await ready()) {
            log.notice("auto-starting profile \(p, privacy: .public)")
            setBusyNow("Starting")
            let r = await Shell.run([Paths.ctl, "start"], timeout: 600,
                                    extraEnv: ["COLIMABAR_PROFILE": p, "COLIMABAR_APP": "1"])
            localBusy = nil
            if !r.ok { log.error("auto-start: colima-ctl.sh start exited \(r.status)") }
        }
        var streak = 0
        let deadline = Date().addingTimeInterval(60)
        while Date() < deadline {
            streak = await ready() ? streak + 1 : 0
            if streak >= 3 {
                // Refresh the cached API version from the real daemon (a Colima
                // update can change it) before more pings are answered locally.
                if let v = await probe.get("/_ping", timeout: 3)?.headers["api-version"] {
                    proxy.apiVersion = v
                    Defaults.set(v, "apiVersion")
                }
                Task { await refreshAll() }
                return true
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
        Notifier.shared.post("Colima didn't become ready. Check the Colima log.")
        return false
    }

    /// Whether a `ps` command line is a `colima start`/`restart` in progress for
    /// `profile`. `colima start -f` is a long-lived foreground supervisor (e.g.
    /// a launchd job), not a start in progress.
    nonisolated static func isStartInProgress(command: String, profile: String) -> Bool {
        let words = command.split(whereSeparator: \.isWhitespace).map(String.init)
        guard let i = words.firstIndex(where: { $0 == "colima" || $0.hasSuffix("/colima") }),
              i + 1 < words.count, ["start", "restart"].contains(words[i + 1]) else { return false }
        if words.contains("-f") || words.contains("--foreground") { return false }
        var named: String?
        for (j, w) in words.enumerated() {
            if (w == "--profile" || w == "-p"), j + 1 < words.count { named = words[j + 1] }
            if w.hasPrefix("--profile=") { named = String(w.dropFirst("--profile=".count)) }
        }
        // `colima start NAME` also selects a profile.
        if named == nil, i + 2 < words.count, !words[i + 2].hasPrefix("-") { named = words[i + 2] }
        return (named ?? "default") == profile
    }

    /// True while a `colima start` for this profile runs (e.g. from a terminal,
    /// which leaves no busy marker).
    nonisolated private static func colimaStartRunning(_ profile: String) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        p.arguments = ["-f", "colima (start|restart)"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return false }
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return false }
        // pgrep prints pids only; check each command line for the profile.
        for pid in out.split(separator: "\n") {
            let ps = Process()
            ps.executableURL = URL(fileURLWithPath: "/bin/ps")
            ps.arguments = ["-o", "command=", "-p", String(pid)]
            let pp = Pipe()
            ps.standardOutput = pp
            ps.standardError = FileHandle.nullDevice
            guard (try? ps.run()) != nil else { continue }
            let cmd = String(decoding: pp.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            ps.waitUntilExit()
            if isStartInProgress(command: cmd, profile: profile) { return true }
        }
        return false
    }

    /// Stops the VM once it has had no running containers for the chosen time.
    /// Builds, pulls and pushes show no running container, so live docker
    /// traffic through the proxy also counts as "not idle".
    private func checkIdle() {
        guard autoStop, state == .running, busy == nil, !stopping, running.isEmpty,
              proxy.activeTransfers() == 0 else {
            if idleSince != nil { idleSince = nil }
            return
        }
        guard let since = idleSince else {
            idleSince = Date()
            return
        }
        guard Date().timeIntervalSince(since) >= Double(autoStopMinutes * 60) else { return }
        // The list can be stale (events missed during a reconnect): confirm
        // with a fresh one right before stopping.
        stopping = true
        let gen = generation
        Task {
            defer { stopping = false }
            // No fresh list (timeout, error): don't stop on stale data.
            let fresh = await refreshContainers()
            guard fresh, gen == generation, autoStop, state == .running, busy == nil,
                  running.isEmpty, proxy.activeTransfers() == 0 else {
                idleSince = nil
                return
            }
            idleSince = nil
            log.notice("auto-stopping idle profile \(self.profile, privacy: .public)")
            ctl("auto-stop", "\(autoStopMinutes)")
        }
    }

    // MARK: - Live stats

    /// Only what the open tab needs: `colima list` when the last one is over
    /// a minute old, df for the disk tabs, and routing for the System tab.
    private func becameVisible() {
        Task {
            if Date().timeIntervalSince(lastColima) >= Self.statusMaxAgeOnOpen { await refreshStatus() }
            if state == .running {
                await refreshContainers()
                requestDF()
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
            statStreams[id] = api.stream("/containers/\(id)/stats?stream=1", onLine: { [weak self] line in
                guard let s = try? JSONDecoder().decode(APIStats.self, from: line) else { return }
                let stat = Stat(cpu: s.cpuPercent, memBytes: s.memBytes)
                Task { @MainActor in
                    guard let self, self.generation == gen else { return }
                    self.latest[id] = stat
                }
            }, onEnd: { [weak self] handle in
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
        let mem = latest.values.reduce(0) { $0 + $1.memBytes } / Double(max(vm.memGB, 1) << 30) * 100
        push(&cpuHistory, min(cpu, 100))
        push(&memHistory, min(mem, 100))
    }

    // MARK: - Events

    /// The event types and actions that `handle` uses. dockerd drops all
    /// others, so healthcheck exec events (several per second with many
    /// containers) never wake the app. "health_status" makes dockerd match
    /// every action by prefix, so it also matches "health_status: unhealthy".
    /// No other action here is a prefix of an unwanted one.
    nonisolated static let eventTypes = ["container", "image", "volume"]
    nonisolated static let eventActions = [
        // container
        "create", "start", "restart", "die", "kill", "stop", "oom", "pause", "unpause",
        "rename", "destroy", "health_status",
        // image
        "pull", "tag", "untag", "delete", "import", "load",
        // all three types
        "prune",
    ]

    nonisolated static var eventFilter: String {
        let f = ["type": eventTypes, "event": eventActions]
        let data = (try? JSONSerialization.data(withJSONObject: f, options: [.sortedKeys])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    /// Events that change nothing ColimaBar shows. The server filter already
    /// drops them; this check runs on the stream thread in case one slips through.
    nonisolated static func ignores(action: String) -> Bool {
        action.hasPrefix("exec_") || action == "top"
    }

    private func startEvents() {
        guard hasDockerSocket else { return }
        let filters = DockerAPI.q(Self.eventFilter)
        let gen = generation
        events = api.stream("/events?filters=\(filters)", onLine: { [weak self] line in
            guard let ev = try? JSONDecoder().decode(DockerEvent.self, from: line),
                  !Self.ignores(action: ev.Action ?? "") else { return }
            Task { @MainActor in
                guard let self, self.generation == gen else { return }
                self.handle(ev)
            }
        }, onEnd: { [weak self] handle in
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
            let ctr = (id: id, name: name)
            if action == "oom" {
                Notifier.shared.post("Killed: out of memory", title: name, container: ctr, profile: profile)
            } else if action == "die", let code = attrs["exitCode"], !["0", "130", "137", "143"].contains(code) {
                Notifier.shared.post("Exited with code \(code)", title: name, container: ctr, profile: profile)
            } else if action == "health_status: unhealthy" {
                Notifier.shared.post("Healthcheck is failing", title: name, container: ctr, profile: profile)
            }
        }
        // Coalesce a burst of events (compose up/down) into one refresh.
        let touchesDisk = ev.Type != "container" || ["create", "destroy"].contains(action)
        if touchesDisk { diskDirty = true }
        containerRefresh?.cancel()
        containerRefresh = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await refreshContainers()
            if diskDirty { requestDF() }
        }
    }

    // MARK: - Actions

    /// Runs a colima-ctl.sh action for the selected profile (it owns confirm
    /// dialogs, config edits, the busy marker and notifications), then refreshes.
    func ctl(_ args: String...) {
        let p = profile
        let label: String? = Self.vmActions.contains(args.first ?? "") ? Self.busyLabel(args.first!) : nil
        if let label { setBusyNow(label) }
        Task {
            let r = await Shell.run([Paths.ctl] + args, timeout: 900,
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
                Notifier.shared.post("\(args.first ?? "Action") failed (exit \(r.status)). See \(Paths.ctlLog).")
            }
            // The action is over (done, failed or cancelled): drop the
            // placeholder, but only if a newer action hasn't replaced it.
            if p == profile, localBusy == label { localBusy = nil }
            busy = readBusy()
            await refreshAll()
        }
    }

    /// Actions that start, stop or restart the VM. The UI shows them as busy
    /// right away, not on the next 1s tick, so a second click can't race them.
    private static let vmActions: Set<String> = ["start", "stop", "restart", "resources", "rosetta", "k8s", "disk", "auto-stop"]

    private static func busyLabel(_ action: String) -> String {
        switch action {
        case "start": return "Starting"
        case "stop", "auto-stop": return "Stopping"
        default: return "Restarting"
        }
    }

    private func setBusyNow(_ label: String) {
        localBusy = label
        if busy == nil { busy = label }
    }

    func record(_ title: String, _ body: String, containerID: String?) {
        alerts.insert(AlertItem(title: title, body: body, containerID: containerID), at: 0)
        if alerts.count > 20 { alerts.removeLast(alerts.count - 20) }
    }

    func container(withID id: String) -> Container? { containers.first { $0.id == id } }

    /// Client for a profile's socket: the live one for the selected profile.
    private func api(for p: String) -> DockerAPI {
        p == profile ? api : DockerAPI(socketPath: Paths.socket(p))
    }

    /// Container lifecycle calls that need no confirmation go straight to the API.
    /// The timeout covers containers with a long stop grace period.
    func container(_ id: String, _ verb: String, profile p: String? = nil) {
        let client = api(for: p ?? profile)
        Task {
            let r = await client.post("/containers/\(id)/\(verb)", timeout: verb == "start" ? 60 : 180)
            if !(r?.ok ?? false) {
                let msg = r.flatMap { try? JSONDecoder().decode([String: String].self, from: $0.body)["message"] }
                Notifier.shared.post("\(verb.capitalized) failed: \(msg ?? "no response from Docker")")
            }
            await refreshContainers()
        }
    }

    /// stop|start|restart every container of a compose project. At most
    /// `projectConcurrency` requests run at once: each one holds a thread
    /// for up to 180 s.
    func project(_ name: String, _ verb: String) {
        let ids = containers.filter { $0.project == name && (verb == "start" ? !$0.isRunning : $0.isRunning || verb == "restart") }
            .map(\.id)
        let names = Dictionary(uniqueKeysWithValues: containers.map { ($0.id, $0.name) })
        Task { [api] in
            let failed = await Self.failures(ids, limit: Self.projectConcurrency) { id in
                let r = await api.post("/containers/\(id)/\(verb)", timeout: 180)
                return (r?.ok ?? false) ? nil : names[id] ?? String(id.prefix(12))
            }
            if !failed.isEmpty {
                Notifier.shared.post("\(verb.capitalized) failed for \(failed.sorted().joined(separator: ", ")).")
            }
            await refreshContainers()
        }
    }

    nonisolated static let projectConcurrency = 8

    /// Runs `body` for each item, at most `limit` at a time, and returns the
    /// non-nil results (the names that failed).
    nonisolated static func failures<T: Sendable>(_ items: [T], limit: Int,
                                                  _ body: @escaping @Sendable (T) async -> String?) async -> [String] {
        await withTaskGroup(of: String?.self) { g in
            var rest = items[...]
            for _ in 0..<min(max(limit, 1), items.count) {
                let item = rest.removeFirst()
                g.addTask { await body(item) }
            }
            var out: [String] = []
            for await r in g {
                if let r { out.append(r) }
                if let item = rest.popFirst() { g.addTask { await body(item) } }
            }
            return out
        }
    }

    func openLogs(id: String, name: String, profile p: String? = nil) {
        let target = p ?? profile
        LogWindows.shared.open(api: api(for: target), id: id, name: name) { [weak self] in
            self?.terminal(profile: target, ["ctr-logs", name])
        }
    }

    func terminal(_ args: String...) {
        terminal(profile: profile, args)
    }

    func terminal(profile p: String, _ args: [String]) {
        func q(_ s: String) -> String { "'\(s.replacingOccurrences(of: "'", with: "'\\''"))'" }
        Shell.inTerminal("COLIMABAR_PROFILE=\(q(p)) " + ([Paths.ctl] + args).map(q).joined(separator: " "))
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

/// Decides when the next `/system/df` runs. At most one runs at a time, and
/// a new one starts at least `minGap` after the last one ended. Requests that
/// come in meanwhile join into one more run after the gap.
struct DFGate {
    enum Step: Equatable {
        case none
        case run(after: TimeInterval)
    }

    var minGap: TimeInterval = 30
    private(set) var scheduled = false   // a run waits for the gap or is in flight
    private(set) var inFlight = false
    private(set) var again = false       // requested while a run was in flight
    private(set) var lastEnd: Date?

    mutating func request(now: Date) -> Step {
        if inFlight { again = true; return .none }
        if scheduled { return .none }     // the waiting run covers this request
        scheduled = true
        let wait = lastEnd.map { max(0, minGap - now.timeIntervalSince($0)) } ?? 0
        return .run(after: wait)
    }

    mutating func begin() { inFlight = true }

    /// Call when the run ends (with or without data). Returns the run that
    /// covers requests made while it was in flight.
    mutating func end(now: Date) -> Step {
        inFlight = false
        scheduled = false
        lastEnd = now
        guard again else { return .none }
        again = false
        return request(now: now)
    }

    /// The waiting run did not start because nothing shows the data now.
    mutating func skip() {
        scheduled = false
        again = false
    }
}

/// Watches the directories that change when any Colima profile starts,
/// stops, appears or goes away: ~/.config/colima, each profile directory,
/// Lima's `_lima` directory and each Lima instance directory. Lima creates
/// and removes ha.sock and ha.pid in the instance directory. Changes that
/// come close together call `onChange` once. It is called at most once per
/// `minGap`, and a change is never dropped, only delayed.
@MainActor
final class ColimaDirWatcher {
    private let root: String
    private let debounce: Duration
    private let minGap: Duration
    private let onChange: @MainActor () -> Void
    private var sources: [String: DispatchSourceFileSystemObject] = [:]
    private var pending: Task<Void, Never>?
    private var lastFire: ContinuousClock.Instant?

    /// XDG_CONFIG_HOME is pinned to ~/.config (see Shell), so Colima uses this root.
    init(root: String = "\(Paths.home)/.config/colima", debounce: Duration = .seconds(2),
         minGap: Duration = .seconds(10), onChange: @escaping @MainActor () -> Void) {
        self.root = root
        self.debounce = debounce
        self.minGap = minGap
        self.onChange = onChange
        rearm()
    }

    deinit {
        for s in sources.values { s.cancel() }
    }

    var watched: Set<String> { Set(sources.keys) }

    /// The directories to watch that exist now. Names that start with "_"
    /// or "." are Colima's and Lima's own stores, not profiles or instances.
    nonisolated static func watchPaths(root: String) -> Set<String> {
        let fm = FileManager.default
        func isDir(_ p: String) -> Bool {
            var d: ObjCBool = false
            return fm.fileExists(atPath: p, isDirectory: &d) && d.boolValue
        }
        func children(_ dir: String) -> [String] {
            ((try? fm.contentsOfDirectory(atPath: dir)) ?? [])
                .filter { !$0.hasPrefix("_") && !$0.hasPrefix(".") }
                .map { "\(dir)/\($0)" }
                .filter(isDir)
        }
        guard isDir(root) else { return [] }
        var out: Set<String> = [root]
        out.formUnion(children(root))
        let lima = "\(root)/_lima"
        if isDir(lima) {
            out.insert(lima)
            out.formUnion(children(lima))
        }
        return out
    }

    /// Starts watching new directories and stops watching removed ones.
    func rearm() {
        let want = Self.watchPaths(root: root)
        for (path, s) in sources where !want.contains(path) {
            s.cancel()
            sources[path] = nil
        }
        for path in want where sources[path] == nil {
            let fd = open(path, O_EVTONLY)
            guard fd >= 0 else { continue }
            let s = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .delete, .rename],
                                                              queue: .main)
            s.setEventHandler { [weak self, weak s] in
                guard let s else { return }
                let gone = !s.data.isDisjoint(with: [.delete, .rename])
                MainActor.assumeIsolated { self?.changed(path, gone: gone) }
            }
            s.setCancelHandler { close(fd) }
            s.resume()
            sources[path] = s
        }
    }

    private func changed(_ path: String, gone: Bool) {
        // The descriptor now points at a removed or moved directory. Drop it,
        // so the next rearm() opens the path again if it exists.
        if gone, let s = sources.removeValue(forKey: path) { s.cancel() }
        // A callback is already scheduled: it also covers this change.
        guard pending == nil else { return }
        let now = ContinuousClock.now
        var at = now + debounce
        if let lastFire, lastFire + minGap > at { at = lastFire + minGap }
        pending = Task { [weak self] in
            try? await Task.sleep(until: at, clock: .continuous)
            guard let self else { return }
            self.pending = nil
            self.lastFire = .now
            self.rearm()
            self.onChange()
        }
    }
}

extension Optional where Wrapped == Bool {
    var orFalse: Bool { self ?? false }
}

/// Typed-ish UserDefaults access that distinguishes "unset" from false/0.
enum Defaults {
    static func string(_ k: String) -> String? { UserDefaults.standard.string(forKey: k) }
    static func bool(_ k: String) -> Bool? { UserDefaults.standard.object(forKey: k) as? Bool }
    static func int(_ k: String) -> Int? { UserDefaults.standard.object(forKey: k) as? Int }
    static func set(_ v: Any, _ k: String) { UserDefaults.standard.set(v, forKey: k) }
}
