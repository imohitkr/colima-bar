import AppKit
import Foundation
import Observation

enum VMState: Equatable { case unknown, running, stopped }

/// Single source of truth for the dashboard. Every property is only assigned
/// when its value actually changed, so SwiftUI redraws just the cells whose
/// text differs and nothing shifts while the popover is open.
///
/// Container data comes straight from the Docker Engine API on Colima's socket
/// (no process per refresh, streaming stats). Colima itself has no API, so VM
/// facts come from `colima list -j`, run only when the VM goes up/down or once
/// a minute.
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
    var notifyOnCrash = UserDefaults.standard.object(forKey: "notifyOnCrash") as? Bool ?? true {
        didSet { UserDefaults.standard.set(notifyOnCrash, forKey: "notifyOnCrash") }
    }

    /// Number of dashboard surfaces (popover, window) currently on screen.
    /// Live stats only stream while this is > 0.
    var visibleCount = 0 {
        didSet {
            guard (oldValue > 0) != (visibleCount > 0) else { return }
            visibleCount > 0 ? becameVisible() : becameHidden()
        }
    }

    var running: [Container] { containers.filter(\.isRunning) }
    var stopped: [Container] { containers.filter { !$0.isRunning } }
    var unhealthyCount: Int { containers.filter { $0.health == "unhealthy" }.count }

    let api = DockerAPI()
    private var events: StreamHandle?
    private var statStreams: [String: StreamHandle] = [:]
    private var latest: [String: Stat] = [:]   // written by stat streams, published once a second
    private var tickTask: Task<Void, Never>?
    private var containerRefresh: Task<Void, Never>?
    private var lastDF = Date.distantPast
    private var lastColima = Date.distantPast
    private let historyLen = 60

    func start() {
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

    /// 1s heartbeat. Cheap work only: a stat() of the busy marker, publishing
    /// the stat streams' latest numbers, and a socket /_ping every few seconds.
    private func tick(_ n: Int) async {
        let b = FileManager.default.fileExists(atPath: Shell.busyPath)
            ? (try? String(contentsOfFile: Shell.busyPath, encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "Working"
            : nil
        if b != busy {
            let finished = busy != nil && b == nil
            busy = b
            if finished { await refreshAll() }
        }
        if visibleCount > 0 { publishStats() }

        if n % (visibleCount > 0 ? 3 : 10) == 0 {
            let up = await api.get("/_ping", timeout: 2)?.ok ?? false
            let stale = Date().timeIntervalSince(lastColima) > 60
            if up != (state == .running) || stale {
                await refreshStatus()
            } else if up, events == nil {
                startEvents()
            }
        }
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
        let r = await Shell.run(["colima", "list", "-j"], timeout: 10)
        let line = r.out.split(separator: "\n").first.map(String.init) ?? ""
        let info = try? JSONDecoder().decode(ColimaListJSON.self, from: Data(line.utf8))
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
                let s = await Shell.run(["colima", "status", "-j"], timeout: 10)
                if let st = try? JSONDecoder().decode(ColimaStatusJSON.self, from: Data(s.out.utf8)) {
                    v.driver = st.driver ?? ""
                    v.mountType = st.mount_type ?? ""
                }
            }
            set(\.vm, v)
        }
        if let yaml = try? String(contentsOfFile: Shell.configPath, encoding: .utf8) {
            set(\.rosetta, Parse.yaml(yaml, key: "rosetta") == "true")
            set(\.k8s, Parse.yaml(yaml, key: "enabled", section: "kubernetes") == "true")
        }
        set(\.state, newState)

        if newState == .running {
            if events == nil { startEvents() }
            if !wasRunning { await refreshContainers() }
        } else {
            events?.cancel()
            events = nil
            syncStatStreams()
            set(\.containers, [])
            set(\.stats, [:])
            set(\.images, [])
            set(\.volumes, [])
            set(\.df, [])
        }
    }

    func refreshContainers() async {
        guard let r = await api.get("/containers/json?all=1"), r.ok,
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
        guard let r = await api.get("/system/df", timeout: 30), r.ok,
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

    // MARK: - Live stats

    private func becameVisible() {
        Task {
            await refreshAll()
            if Date().timeIntervalSince(lastDF) > 30 { await refreshDF() }
        }
        syncStatStreams()
    }

    private func becameHidden() {
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
        for id in want where statStreams[id] == nil {
            statStreams[id] = api.stream("/containers/\(id)/stats?stream=1", onLine: { [weak self] line in
                guard let s = try? JSONDecoder().decode(APIStats.self, from: line) else { return }
                let stat = Stat(cpu: s.cpuPercent, memBytes: s.memBytes)
                Task { @MainActor in self?.latest[id] = stat }
            }, onEnd: { [weak self] in
                Task { @MainActor in self?.statStreams[id] = nil; self?.latest[id] = nil }
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
        events = api.stream("/events?filters=\(filters)", onLine: { [weak self] line in
            guard let ev = try? JSONDecoder().decode(DockerEvent.self, from: line) else { return }
            Task { @MainActor in self?.handle(ev) }
        }, onEnd: { [weak self] in
            // VM stopped or socket hiccup: the heartbeat's ping reconnects.
            Task { @MainActor in self?.events = nil }
        })
    }

    private func handle(_ ev: DockerEvent) {
        let attrs = ev.Actor?.Attributes ?? [:]
        let action = ev.Action ?? ""
        // Stats/exec events fire constantly and change nothing we show.
        if action.hasPrefix("exec_") || action == "top" { return }
        if notifyOnCrash, ev.Type == "container" {
            let name = attrs["name"] ?? "container"
            if action == "oom" {
                notify("\(name) was killed: out of memory")
            } else if action == "die", let code = attrs["exitCode"], !["0", "130", "137", "143"].contains(code) {
                notify("\(name) exited with code \(code)")
            } else if action == "health_status: unhealthy" {
                notify("\(name) is unhealthy")
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

    /// Runs a colima-ctl.sh action (it owns confirm dialogs, config edits,
    /// the busy marker and notifications), then refreshes.
    func ctl(_ args: String...) {
        Task {
            _ = await Shell.run([Shell.ctl] + args, timeout: 900)
            await refreshAll()
        }
    }

    /// Container lifecycle calls that need no confirmation go straight to the API.
    func container(_ id: String, _ verb: String) {
        Task {
            let r = await api.post("/containers/\(id)/\(verb)", timeout: 60)
            if !(r?.ok ?? false) {
                let msg = r.flatMap { try? JSONDecoder().decode([String: String].self, from: $0.body)["message"] }
                notify("\(verb.capitalized) failed: \(msg ?? "no response from Docker")")
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

    func terminal(_ args: String...) {
        let quoted = ([Shell.ctl] + args).map { "'\($0.replacingOccurrences(of: "'", with: "'\\''"))'" }
        Shell.inTerminal(quoted.joined(separator: " "))
    }

    func open(port: Int) {
        if let u = URL(string: "http://localhost:\(port)") { NSWorkspace.shared.open(u) }
    }

    func notify(_ msg: String) {
        let esc = msg.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        Task { _ = await Shell.run(["osascript", "-e", "display notification \"\(esc)\" with title \"Colima\""]) }
    }

    // MARK: - Helpers

    private func set<T: Equatable>(_ kp: ReferenceWritableKeyPath<ColimaModel, T>, _ v: T) {
        if self[keyPath: kp] != v { self[keyPath: kp] = v }
    }

    private func push(_ arr: inout [Double], _ v: Double) {
        arr.append(v)
        if arr.count > historyLen { arr.removeFirst(arr.count - historyLen) }
    }
}
