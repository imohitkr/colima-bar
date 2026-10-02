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
/// goes up/down or once a minute.
@MainActor @Observable
final class ColimaModel {
    var state: VMState = .unknown
    var busy: String?
    var vm = VMInfo()
    var rosetta = false
    var k8s = false
    var containers: [Container] = []
    var stats: [String: Stat] = [:]     // by container id
    var cpuHistory: [Double] = []       // % of VM CPU used by containers
    var memHistory: [Double] = []       // % of VM memory used by containers
    var df: [DFRow] = []
    var images: [ImageRow] = []
    var volumes: [VolumeRow] = []
    var profiles: [ProfileRow] = []
    var routing = Routing.Status()
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
    var autoStopMinutes = Defaults.int("autoStopMinutes") ?? 30 {
        didSet { Defaults.set(autoStopMinutes, "autoStopMinutes"); idleSince = nil }
    }

    /// Number of dashboard surfaces (popover, window) currently on screen.
    /// Live stats only stream while this is > 0.
    var visibleCount = 0 {
        didSet {
            guard (oldValue > 0) != (visibleCount > 0) else { return }
            visibleCount > 0 ? becameVisible() : syncStatStreams()
        }
    }

    var running: [Container] { containers.filter(\.isRunning) }
    var stopped: [Container] { containers.filter { !$0.isRunning } }
    var unhealthyCount: Int { containers.filter { $0.health == "unhealthy" }.count }
    var kubeContext: String { Paths.kubeContext(profile) }

    private(set) var api: DockerAPI
    let proxy: SocketProxy
    private let log = Logger(subsystem: "com.imohitkr.ColimaBar", category: "model")
    private var events: StreamHandle?
    private var statStreams: [String: StreamHandle] = [:]
    private var latest: [String: Stat] = [:]   // written by stat streams, published once a second
    private var tickTask: Task<Void, Never>?
    private var containerRefresh: Task<Void, Never>?
    private var lastDF = Date.distantPast
    private var lastColima = Date.distantPast
    private var isDebug = false
    private var generation = 0                 // bumps on profile switch; stale callbacks are ignored
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
        }
        Task { await refreshAll() }
        tickTask = Task {
            var n = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                n += 1
                await tick(n)
            }
        }
    }

    /// Called on quit: the stable socket becomes a symlink to Colima's, so
    /// docker clients keep working without ColimaBar.
    func shutdown() {
        proxy.stop()
    }

    /// 1s heartbeat. Cheap work only: a stat() of the busy marker, publishing
    /// the stat streams' latest numbers, and a socket /_ping every few seconds.
    private func tick(_ n: Int) async {
        let b = Self.readBusy()
        if b != busy {
            let finished = busy != nil && b == nil
            busy = b
            if finished { await refreshAll() }
        }
        if visibleCount > 0 { publishStats() }

        if n % (visibleCount > 0 ? 3 : 10) == 0 {
            let ping = await api.get("/_ping", timeout: 2)
            let up = ping?.ok ?? false
            if let v = ping?.headers["api-version"], v != proxy.apiVersion {
                proxy.apiVersion = v
                Defaults.set(v, "apiVersion")
            }
            let stale = Date().timeIntervalSince(lastColima) > 60
            if up != (state == .running) || stale {
                await refreshStatus()
            } else if up, events == nil {
                startEvents()
            }
        }
        checkIdle()
    }

    /// The busy marker colima-ctl.sh writes while a long action runs. One left
    /// behind by a killed script is ignored after 20 minutes.
    private static func readBusy() -> String? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: Paths.busy),
              let mtime = attrs[.modificationDate] as? Date else { return nil }
        if Date().timeIntervalSince(mtime) > 20 * 60 {
            try? FileManager.default.removeItem(atPath: Paths.busy)
            return nil
        }
        return (try? String(contentsOfFile: Paths.busy, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "Working"
    }

    // MARK: - Refresh

    func refreshAll() async {
        await refreshStatus()
        if state == .running {
            await refreshContainers()
            if visibleCount > 0 { await refreshDF() }
        }
    }

    func refreshStatus() async {
        lastColima = Date()
        guard Shell.which("colima") != nil else {
            set(\.state, .notInstalled)
            return
        }
        let gen = generation
        let r = await Shell.run(["colima", "list", "-j"], timeout: 10)
        guard gen == generation else { return }
        let dec = JSONDecoder()
        let all = r.out.split(separator: "\n").compactMap { try? dec.decode(ColimaListJSON.self, from: Data($0.utf8)) }
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
                await refreshContainers()
                // `colima start` switches the docker context back to colima.
                if !isDebug { Task {
                    await Routing.apply()
                    routing = await Routing.status()
                } }
            }
        } else {
            clearVMData()
        }
    }

    private func clearVMData() {
        events?.cancel()
        events = nil
        syncStatStreams()
        set(\.containers, [])
        set(\.stats, [:])
        set(\.images, [])
        set(\.volumes, [])
        set(\.df, [])
        cpuHistory = []
        memHistory = []
    }

    private func switchProfile() {
        generation += 1
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

    func refreshContainers() async {
        let gen = generation
        guard let r = await api.get("/containers/json?all=1"), r.ok, gen == generation,
              let list = try? JSONDecoder().decode([APIContainer].self, from: r.body) else { return }
        let mapped = list.map { c in
            Container(id: c.Id, name: c.Names.first.map { String($0.drop { $0 == "/" }) } ?? String(c.Id.prefix(12)),
                      image: c.Image, state: c.State, status: c.Status,
                      ports: Array(Set((c.Ports ?? []).compactMap { $0.IP != nil ? $0.PublicPort : nil })).sorted(),
                      project: c.Labels?["com.docker.compose.project"])
        }
        // Stable order by name: rows never reorder because a number changed.
        set(\.containers, mapped.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending })
        syncStatStreams()
    }

    func refreshDF() async {
        let gen = generation
        guard let r = await api.get("/system/df", timeout: 30), r.ok, gen == generation,
              let d = try? JSONDecoder().decode(APIDF.self, from: r.body) else { return }
        lastDF = Date()
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

    /// Called by the proxy (off the main thread) when a docker request arrives
    /// while the VM is down: start it and wait until its socket answers.
    private func wakeForProxy() async -> Bool {
        let socket = Paths.socket(profile)
        if UnixSocket.canConnect(socket) { return true }
        log.notice("auto-starting profile \(self.profile, privacy: .public)")
        if busy == nil {
            Task { _ = await Shell.run([Paths.ctl, "start"], timeout: 600, extraEnv: ["COLIMABAR_PROFILE": profile]) }
        }
        for _ in 0..<300 {
            try? await Task.sleep(for: .seconds(1))
            if UnixSocket.canConnect(socket) {
                Task { await refreshAll() }
                return true
            }
        }
        Notifier.shared.post("Colima didn't start within 5 minutes. Check the Colima log.")
        return false
    }

    /// Stops the VM once it has had no running containers for the chosen time.
    private func checkIdle() {
        guard autoStop, state == .running, busy == nil, running.isEmpty else {
            if idleSince != nil { idleSince = nil }
            return
        }
        guard let since = idleSince else {
            idleSince = Date()
            return
        }
        if Date().timeIntervalSince(since) >= Double(autoStopMinutes * 60) {
            idleSince = nil
            log.notice("auto-stopping idle profile \(self.profile, privacy: .public)")
            ctl("auto-stop", "\(autoStopMinutes)")
        }
    }

    // MARK: - Live stats

    private func becameVisible() {
        Task {
            await refreshAll()
            if Date().timeIntervalSince(lastDF) > 30 { await refreshDF() }
            routing = await Routing.status()
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
            }, onEnd: { [weak self] in
                Task { @MainActor in
                    guard let self, self.generation == gen else { return }
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

    private func startEvents() {
        let filters = DockerAPI.q(#"{"type":["container","image","volume"]}"#)
        let gen = generation
        events = api.stream("/events?filters=\(filters)", onLine: { [weak self] line in
            guard let ev = try? JSONDecoder().decode(DockerEvent.self, from: line) else { return }
            Task { @MainActor in
                guard let self, self.generation == gen else { return }
                self.handle(ev)
            }
        }, onEnd: { [weak self] in
            // VM stopped or socket hiccup: the heartbeat's ping reconnects.
            Task { @MainActor in
                guard let self, self.generation == gen else { return }
                self.events = nil
            }
        })
    }

    private func handle(_ ev: DockerEvent) {
        let attrs = ev.Actor?.Attributes ?? [:]
        let action = ev.Action ?? ""
        // Stats/exec events fire constantly and change nothing we show.
        if action.hasPrefix("exec_") || action == "top" { return }
        if notifyOnCrash, ev.Type == "container", let id = ev.Actor?.ID {
            let name = attrs["name"] ?? "container"
            let ctr = (id: id, name: name)
            if action == "oom" {
                Notifier.shared.post("Killed: out of memory", title: name, container: ctr)
            } else if action == "die", let code = attrs["exitCode"], !["0", "130", "137", "143"].contains(code) {
                Notifier.shared.post("Exited with code \(code)", title: name, container: ctr)
            } else if action == "health_status: unhealthy" {
                Notifier.shared.post("Healthcheck is failing", title: name, container: ctr)
            }
        }
        // Coalesce a burst of events (compose up/down) into one refresh.
        let touchesDisk = ev.Type != "container" || ["create", "destroy"].contains(action)
        if touchesDisk { lastDF = .distantPast }
        containerRefresh?.cancel()
        containerRefresh = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await refreshContainers()
            if visibleCount > 0, lastDF == .distantPast { await refreshDF() }
        }
    }

    // MARK: - Actions

    /// Runs a colima-ctl.sh action for the selected profile (it owns confirm
    /// dialogs, config edits, the busy marker and notifications), then refreshes.
    func ctl(_ args: String...) {
        let p = profile
        Task {
            _ = await Shell.run([Paths.ctl] + args, timeout: 900, extraEnv: ["COLIMABAR_PROFILE": p])
            await refreshAll()
        }
    }

    /// Container lifecycle calls that need no confirmation go straight to the API.
    func container(_ id: String, _ verb: String) {
        Task {
            let r = await api.post("/containers/\(id)/\(verb)", timeout: 60)
            if !(r?.ok ?? false) {
                let msg = r.flatMap { try? JSONDecoder().decode([String: String].self, from: $0.body)["message"] }
                Notifier.shared.post("\(verb.capitalized) failed: \(msg ?? "no response from Docker")")
            }
            await refreshContainers()
        }
    }

    /// stop|start|restart every container of a compose project.
    func project(_ name: String, _ verb: String) {
        let ids = containers.filter { $0.project == name && (verb == "start" ? !$0.isRunning : $0.isRunning || verb == "restart") }
            .map(\.id)
        Task {
            await withTaskGroup(of: Void.self) { g in
                for id in ids { g.addTask { [api] in _ = await api.post("/containers/\(id)/\(verb)", timeout: 60) } }
            }
            await refreshContainers()
        }
    }

    func openLogs(id: String, name: String) {
        LogWindows.shared.open(api: api, id: id, name: name) { [weak self] in
            self?.terminal("ctr-logs", name)
        }
    }

    func terminal(_ args: String...) {
        let quoted = ([Paths.ctl] + args).map { "'\($0.replacingOccurrences(of: "'", with: "'\\''"))'" }
        Shell.inTerminal("COLIMABAR_PROFILE='\(profile)' " + quoted.joined(separator: " "))
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

/// Typed-ish UserDefaults access that distinguishes "unset" from false/0.
enum Defaults {
    static func string(_ k: String) -> String? { UserDefaults.standard.string(forKey: k) }
    static func bool(_ k: String) -> Bool? { UserDefaults.standard.object(forKey: k) as? Bool }
    static func int(_ k: String) -> Int? { UserDefaults.standard.object(forKey: k) as? Int }
    static func set(_ v: Any, _ k: String) { UserDefaults.standard.set(v, forKey: k) }
}
