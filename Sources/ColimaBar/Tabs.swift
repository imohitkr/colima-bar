import ServiceManagement
import SwiftUI

// MARK: - Containers

struct ContainersTab: View {
    let model: ColimaModel
    @Bindable var ui: ViewState

    // This body must not read stats or history: they change every second.
    // Only StatCells reads them, so a tick redraws just those numbers.
    var body: some View {
        let groups = grouped
        // Lazy: opening the dashboard builds only the rows on screen.
        LazyVStack(alignment: .leading, spacing: 6) {
            if groups.isEmpty {
                Empty(text: model.containers.isEmpty ? "No containers" : "No matches")
            }
            ForEach(groups, id: \.key) { g in
                let isCollapsed = Binding(
                    get: { ui.collapsed.contains(g.key) },
                    set: { if $0 { ui.collapsed.insert(g.key) } else { ui.collapsed.remove(g.key) } })
                SectionHeader(title: g.title, collapsed: isCollapsed, hint: g.project == nil ? Help.standalone : Help.projectGroup) {
                    if let project = g.project {
                        IconButton("play.fill", "Start all in \(project)") { model.project(project, "start") }
                        IconButton("arrow.clockwise", "Restart all in \(project)") { model.project(project, "restart") }
                        IconButton("stop.fill", "Stop all in \(project)") { model.project(project, "stop") }
                    } else if g.key == "~standalone", model.running.count > 1 {
                        Button("Stop all") { model.ctl("stop-all") }.buttonStyle(.borderless).font(.caption)
                            .hint(Help.stopAll)
                    }
                }
                if !isCollapsed.wrappedValue {
                    ForEach(g.items) { c in
                        ContainerRow(model: model, c: c)
                    }
                }
            }
            // Below the list: a new alert must not push the rows you're
            // reading down.
            if !model.alerts.isEmpty || !model.notificationsAllowed {
                AlertsStrip(model: model).padding(.top, 6)
            }
        }
    }

    private struct Group {
        let key: String
        let title: String
        let project: String?
        let items: [Container]
    }

    /// Compose projects first (alphabetical), then standalone containers.
    /// Inside each group: running before stopped, then by name.
    private var grouped: [Group] {
        let q = ui.search.lowercased()
        let list = model.containers.filter { c in
            (!ui.runningOnly || c.isRunning) &&
            (q.isEmpty || c.name.lowercased().contains(q) || c.image.lowercased().contains(q)
                || (c.project?.lowercased().contains(q) ?? false))
        }
        let order: (Container, Container) -> Bool = { a, b in
            a.isRunning != b.isRunning ? a.isRunning : a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
        var out: [Group] = []
        let byProject = Dictionary(grouping: list.filter { $0.project != nil }, by: { $0.project! })
        for p in byProject.keys.sorted() {
            let items = byProject[p]!.sorted(by: order)
            let up = items.filter(\.isRunning).count
            out.append(Group(key: "p:\(p)", title: "\(p)  ·  \(up)/\(items.count) running", project: p, items: items))
        }
        let solo = list.filter { $0.project == nil }.sorted(by: order)
        if !solo.isEmpty {
            let up = solo.filter(\.isRunning).count
            out.append(Group(key: "~standalone", title: "Standalone  ·  \(up)/\(solo.count) running",
                             project: nil, items: solo))
        }
        return out
    }
}

/// Recent alerts (crash, OOM, unhealthy, failed actions), so nothing is
/// missed even with notifications off. Buttons work only while the container
/// still exists.
struct AlertsStrip: View {
    @Bindable var model: ColimaModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !model.notificationsAllowed {
                HStack(spacing: 6) {
                    Image(systemName: "bell.slash").foregroundStyle(.orange)
                    Text("Notifications are off for ColimaBar, so alerts only show here.")
                        .font(.caption)
                    Spacer()
                    Button("Enable…") { Notifier.openSettings() }.controlSize(.mini)
                        .hint(Help.enableNotifications)
                }
            }
            if !model.alerts.isEmpty {
                SectionHeader(title: "Recent alerts") {
                    Button("Clear") { model.alerts.removeAll() }.buttonStyle(.borderless).font(.caption)
                        .hint("Dismiss these alerts.")
                }
                ForEach(model.alerts.prefix(5)) { a in
                    let ctr = a.containerID.flatMap { model.container(withID: $0) }
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.caption)
                        VStack(alignment: .leading, spacing: 0) {
                            Text("\(a.title): \(a.body)").font(.system(size: 11)).lineLimit(1)
                            Text(a.date.formatted(date: .omitted, time: .shortened)
                                 + (a.containerID != nil && ctr == nil ? " · container removed" : ""))
                                .font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if let ctr {
                            IconButton("text.alignleft", Help.logs) { model.openLogs(id: ctr.id, name: ctr.name) }
                            IconButton("arrow.clockwise", Help.ctrRestart) { model.container(ctr.id, "restart") }
                        }
                    }
                    .padding(.vertical, 3).padding(.horizontal, 6)
                    .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                }
            }
        }
        .padding(.bottom, 4)
    }
}

struct ContainerRow: View {
    let model: ColimaModel
    let c: Container

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(dot).frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    // Middle truncation keeps suffixes like "-1" visible.
                    Text(c.name).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
                    if let h = c.health {
                        Text(h == "health: starting" ? "starting" : h)
                            .font(.system(size: 9, weight: .medium))
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(healthColor(h).opacity(0.15), in: Capsule())
                            .foregroundStyle(healthColor(h))
                            .hint(h == "healthy" ? Help.healthy : h == "unhealthy" ? Help.unhealthy : Help.starting)
                    }
                }
                Text(c.isRunning ? c.image : "\(c.image) · \(c.status)")
                    .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 4)
            // One port inline leaves room for the name; all ports are in the ••• menu.
            ForEach(c.ports.prefix(1), id: \.self) { p in
                Button(String(p)) { model.open(port: p) }
                    .buttonStyle(.plain)
                    .font(.system(size: 10, weight: .medium).monospacedDigit())
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(.blue.opacity(0.12), in: Capsule())
                    .foregroundStyle(.blue)
                    .hint(Help.port(p))
            }
            if c.isRunning { StatCells(model: model, id: c.id) }
            actions
        }
        .font(.system(size: 11).monospacedDigit())
        .padding(.vertical, 4).padding(.horizontal, 6)
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 6))
        .opacity(c.isRunning ? 1 : 0.75)
    }

    @ViewBuilder private var actions: some View {
        HStack(spacing: 0) {
            if c.isRunning {
                IconButton("text.alignleft", Help.logs) { model.openLogs(id: c.id, name: c.name) }
                IconButton("chevron.left.forwardslash.chevron.right", Help.shell) { model.terminal("ctr-shell", c.name) }
                IconButton("arrow.clockwise", Help.ctrRestart) { model.container(c.id, "restart") }
                IconButton("stop.fill", Help.ctrStop) { model.container(c.id, "stop") }
            } else {
                IconButton("text.alignleft", Help.logs) { model.openLogs(id: c.id, name: c.name) }
                IconButton("play.fill", Help.ctrStart) { model.container(c.id, "start") }
                IconButton("trash", Help.ctrRemove) { model.ctl("ctr-rm", c.name) }
            }
            Menu {
                Button("Logs in iTerm") { model.terminal("ctr-logs", c.name) }
                Divider()
                Button("Copy name") { copy(c.name) }
                Button("Copy ID") { copy(String(c.id.prefix(12))) }
                Button("Copy image") { copy(c.image) }
                Button("Copy exec command") { copy("docker exec -it \(c.name) sh") }
                if !c.ports.isEmpty {
                    Divider()
                    ForEach(c.ports, id: \.self) { p in Button("Open localhost:\(p)") { model.open(port: p) } }
                }
                if c.isRunning {
                    Divider()
                    Button("Remove…") { model.ctl("ctr-rm", c.name) }
                }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 22)
            .hint(Help.more)
        }
        .font(.system(size: 11))
    }

    private var dot: Color {
        if c.health == "unhealthy" { return .red }
        switch c.state {
        case "running": return .green
        case "paused", "restarting": return .orange
        default: return .secondary.opacity(0.6)
        }
    }

    private func healthColor(_ h: String) -> Color {
        h == "healthy" ? .green : h == "unhealthy" ? .red : .orange
    }
}

/// A container's live CPU and memory. It is the only part of a row that
/// reads `model.stats`, so a stats tick redraws these two cells, not the row.
struct StatCells: View {
    let model: ColimaModel
    let id: String

    var body: some View {
        let stat = model.stats[id]
        // Fixed-width, right-aligned, monospaced: numbers tick in place.
        Text(stat.map { String(format: "%.1f%%", $0.cpu) } ?? "–")
            .frame(width: 46, alignment: .trailing)
            .hint(Help.ctrCPU)
        Text(stat.map { Fmt.bytes($0.memBytes) } ?? "–")
            .frame(width: 54, alignment: .trailing)
            .hint(Help.ctrMem)
    }
}

// MARK: - Images

struct ImagesTab: View {
    let model: ColimaModel
    let search: String

    var body: some View {
        let q = search.lowercased()
        let list = model.images.filter { q.isEmpty || $0.repo.lowercased().contains(q) || $0.tag.lowercased().contains(q) }
        let unused = model.images.filter { $0.containers == 0 }
        // Lazy: a long list builds only the rows on screen.
        LazyVStack(alignment: .leading, spacing: 6) {
            SectionHeader(title: "\(model.images.count) images · \(unused.count) unused") {
                Button("Remove dangling") { model.ctl("prune", "dangling") }.buttonStyle(.borderless).font(.caption)
                    .hint(Help.removeDangling)
                Button("Remove unused") { model.ctl("prune", "images") }.buttonStyle(.borderless).font(.caption)
                    .hint(Help.removeUnusedImages)
            }
            if list.isEmpty { Empty(text: model.images.isEmpty ? "No images" : "No matches") }
            ForEach(list) { i in
                HStack(spacing: 8) {
                    Image(systemName: i.dangling ? "square.dashed" : "square.stack.3d.up")
                        .foregroundStyle(.secondary).frame(width: 16)
                        .hint(i.dangling ? Help.dangling : "Image \(i.repo):\(i.tag)")
                    VStack(alignment: .leading, spacing: 1) {
                        Text(i.dangling ? "<none>" : i.repo).font(.system(size: 12, weight: .medium))
                            .lineLimit(1).truncationMode(.head)
                        Text("\(i.tag) · \(i.created.formatted(.relative(presentation: .named)))")
                            .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    if i.containers > 0 {
                        Text("in use").font(.system(size: 9, weight: .medium))
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(.green.opacity(0.15), in: Capsule()).foregroundStyle(.green)
                            .hint(Help.inUse)
                    }
                    Text(Fmt.bytes(i.size)).font(.system(size: 11).monospacedDigit())
                        .frame(width: 60, alignment: .trailing)
                        .hint(Help.imageSize)
                    Menu {
                        Button("Copy reference") { copy(i.ref) }
                        if !i.dangling { Button("Pull latest of this tag") { model.ctl("img-pull", i.ref) } }
                        Divider()
                        Button("Remove…") { model.ctl("img-rm", i.ref) }
                    } label: { Image(systemName: "ellipsis") }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 22)
                }
                .padding(.vertical, 4).padding(.horizontal, 6)
                .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 6))
            }
        }
    }
}

// MARK: - Volumes

struct VolumesTab: View {
    let model: ColimaModel
    let search: String

    var body: some View {
        let q = search.lowercased()
        let list = model.volumes.filter { q.isEmpty || $0.name.lowercased().contains(q) || ($0.project?.lowercased().contains(q) ?? false) }
        let unused = model.volumes.filter { $0.links == 0 }
        // Lazy: a long list builds only the rows on screen.
        LazyVStack(alignment: .leading, spacing: 6) {
            SectionHeader(title: "\(model.volumes.count) volumes · \(unused.count) unused") {
                Button("Remove unused") { model.ctl("prune", "volumes") }.buttonStyle(.borderless).font(.caption)
                    .hint(Help.removeUnusedVolumes)
            }
            if list.isEmpty { Empty(text: model.volumes.isEmpty ? "No volumes" : "No matches") }
            ForEach(list) { v in
                HStack(spacing: 8) {
                    Image(systemName: "externaldrive").foregroundStyle(.secondary).frame(width: 16)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(v.anonymous ? String(v.name.prefix(12)) + "…" : v.name)
                            .font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
                        Text([v.project.map { "compose: \($0)" }, v.anonymous ? "anonymous" : nil,
                              v.links > 0 ? "used by \(v.links)" : "unused"].compactMap { $0 }.joined(separator: " · "))
                            .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .hint(v.anonymous ? Help.anonymous : v.links == 0 ? Help.unusedVolume : "Volume \(v.name), used by \(v.links) container(s).")
                    Spacer(minLength: 4)
                    Text(Fmt.bytes(v.size)).font(.system(size: 11).monospacedDigit())
                        .frame(width: 60, alignment: .trailing)
                    Menu {
                        Button("Copy name") { copy(v.name) }
                        Divider()
                        Button("Remove…") { model.ctl("vol-rm", v.name) }.disabled(v.links > 0)
                    } label: { Image(systemName: "ellipsis") }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 22)
                }
                .padding(.vertical, 4).padding(.horizontal, 6)
                .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 6))
                .opacity(v.links > 0 ? 1 : 0.75)
            }
        }
    }
}

// MARK: - System

/// Picker selections live in an @Observable object, not @State: the SwiftUI
/// macro plugin isn't shipped with Command Line Tools, Observation's is.
@MainActor @Observable
final class SystemForm {
    var cpu = 0
    var mem = 0
    var loginEnabled = LoginItem.isEnabled
    var loginNeedsApproval = false   // filled in off the main thread (runs launchctl)
    var linking = false
    var customIdle = false        // "Custom" picked in the auto-stop picker
    var customMinutes = ""
}

/// Auto-stop timeout choices. `custom` is the picker tag for "Custom".
enum IdleMinutes {
    static let presets = [5, 15, 30, 60]
    static let custom = -1
    static let range = 1...1440

    /// Minutes typed in the custom field, or nil if not a whole number in range.
    static func parse(_ s: String) -> Int? {
        guard let n = Int(s.trimmingCharacters(in: .whitespaces)), range.contains(n) else { return nil }
        return n
    }

    /// The minutes to apply when the custom field is committed (Return or
    /// focus loss). Nil when the text is not valid or equals the current
    /// value, so a commit that changes nothing does not reset the idle timer.
    static func commit(_ s: String, current: Int) -> Int? {
        guard let n = parse(s), n != current else { return nil }
        return n
    }
}

struct SystemTab: View {
    @Bindable var model: ColimaModel
    @Bindable var form: SystemForm
    @FocusState private var minutesFocused: Bool

    private let presets = [("Light", 2, 4), ("Standard", 4, 8), ("Heavy", 8, 16)]
    private let cpuOpts = [2, 4, 6, 8, 10, 12]
    private let memOpts = [4, 8, 12, 16, 24, 32]

    /// The fixed choices, plus the VM's value and the picked value when they
    /// are not among them (Colima's default VM has 2 GB). The VM's value stays
    /// after you pick another one, so you can pick it again, and the picker
    /// always has a selection.
    static func options(_ fixed: [Int], _ extra: Int...) -> [Int] {
        var out = fixed
        for v in extra where v > 0 && !out.contains(v) { out.append(v) }
        return out.count == fixed.count ? fixed : out.sorted()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "VM resources")
            HStack(spacing: 6) {
                ForEach(presets, id: \.0) { p in
                    let active = p.1 == model.vm.cpus && p.2 == model.vm.memGB
                    Button { model.ctl("resources", "\(p.1)", "\(p.2)") } label: {
                        VStack(spacing: 1) {
                            Text(p.0).font(.system(size: 11, weight: .semibold))
                            Text("\(p.1) CPU · \(p.2) GB").font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 5)
                        .background(active ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.08),
                                    in: RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(active ? Color.accentColor : .clear))
                    }
                    .buttonStyle(.plain).disabled(active)
                    .hint(Help.presets)
                }
            }
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
                GridRow {
                    Text("CPU").font(.caption).foregroundStyle(.secondary)
                    Picker("", selection: $form.cpu) { ForEach(Self.options(cpuOpts, model.vm.cpus, form.cpu), id: \.self) { Text("\($0)").tag($0) } }
                        .pickerStyle(.segmented).labelsHidden()
                        .hint(Help.cpu)
                }
                GridRow {
                    Text("Memory").font(.caption).foregroundStyle(.secondary)
                    Picker("", selection: $form.mem) { ForEach(Self.options(memOpts, model.vm.memGB, form.mem), id: \.self) { Text("\($0) GB").tag($0) } }
                        .pickerStyle(.segmented).labelsHidden()
                        .hint(Help.memory)
                }
            }
            HStack {
                Text("Applying restarts the VM; running containers stop.")
                    .font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Button("Apply") { model.ctl("resources", "\(form.cpu)", "\(form.mem)") }
                    .disabled(form.cpu == model.vm.cpus && form.mem == model.vm.memGB)
                    .hint(Help.apply)
            }

            Divider()
            SectionHeader(title: "Features")
            Toggle(isOn: Binding(get: { model.rosetta }, set: { model.ctl("rosetta", $0 ? "on" : "off") })) {
                Label("Rosetta (amd64 emulation)", systemImage: "cpu")
            }
            .hint(Help.rosetta)
            Toggle(isOn: Binding(get: { model.k8s }, set: { model.ctl("k8s", $0 ? "on" : "off") })) {
                Label("Kubernetes (k3s) · context: \(model.kubeContext)", systemImage: "circle.hexagongrid")
            }
            .hint(Help.k8s)
            HStack {
                Label("Disk: \(model.vm.diskGB) GB", systemImage: "internaldrive")
                Spacer()
                ForEach([150, 200, 300].filter { $0 > model.vm.diskGB }, id: \.self) { d in
                    Button("\(d) GB") { model.ctl("disk", "\(d)") }.controlSize(.small)
                }
            }
            .hint(Help.disk)
            Text("Disks can only grow, not shrink.").font(.caption2).foregroundStyle(.secondary)

            Divider()
            SectionHeader(title: "Disk usage")
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                GridRow {
                    Text("Type"); Text("Count"); Text("Size"); Text("Reclaimable").hint(Help.dfReclaimable)
                }
                .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(model.df) { r in
                    GridRow {
                        Text(r.type)
                        Text("\(r.count)").gridColumnAlignment(.trailing)
                        Text(Fmt.bytes(r.size)).gridColumnAlignment(.trailing)
                        Text(Fmt.bytes(r.reclaimable)).gridColumnAlignment(.trailing)
                            .foregroundStyle(r.reclaimable > 0 ? .orange : .secondary)
                    }
                    .font(.system(size: 11).monospacedDigit())
                    .hint(dfHelp(r.type))
                }
            }
            HStack(spacing: 6) {
                Button("Dangling + build cache") { model.ctl("prune", "dangling") }.hint(Help.pruneDangling)
                Button("Unused images") { model.ctl("prune", "images") }.hint(Help.pruneImages)
                Button("Unused volumes") { model.ctl("prune", "volumes") }.hint(Help.pruneVolumes)
                Button("Full cleanup") { model.ctl("prune", "all") }.hint(Help.pruneAll)
            }
            .controlSize(.small)

            Divider()
            SectionHeader(title: "Auto-start & auto-stop")
            Toggle(isOn: $model.autoStart) {
                Label("Start Colima when something uses docker", systemImage: "bolt.badge.automatic")
            }
            .hint(Help.autoStart)
            VStack(alignment: .leading, spacing: 3) {
                RouteRow(ok: model.routing.context, text: "docker context: \(Routing.contextName)", help: Help.routeContext)
                RouteRow(ok: model.routing.launchd, text: "Apps & IDE test runners (launchd DOCKER_HOST)", help: Help.routeLaunchd)
                RouteRow(ok: model.routing.testcontainers, text: "testcontainers (~/.testcontainers.properties)", help: Help.routeTestcontainers)
                HStack {
                    RouteRow(ok: model.routing.varRun, text: "/var/run/docker.sock", help: Help.routeVarRun)
                    if !model.routing.varRun {
                        Button(form.linking ? "Linking…" : "Link (admin)") {
                            form.linking = true
                            Task {
                                if !(await Routing.linkVarRun()) { model.notify("Couldn't link /var/run/docker.sock") }
                                await model.refreshRouting()
                                form.linking = false
                            }
                        }
                        .controlSize(.mini).disabled(form.linking)
                        .hint(Help.linkVarRun)
                    }
                }
            }
            .padding(.leading, 4)
            .opacity(model.autoStart ? 1 : 0.5)
            Toggle(isOn: $model.autoStop) {
                Label("Stop Colima when idle", systemImage: "moon.zzz")
            }
            .hint(Help.autoStop)
            HStack(spacing: 8) {
                Picker("Auto-stop after", selection: idleSelection) {
                    ForEach(IdleMinutes.presets, id: \.self) { Text("\($0) min").tag($0) }
                    Text("Custom").tag(IdleMinutes.custom)
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 250)
                .hint(Help.autoStopMinutes)
                if idleSelection.wrappedValue == IdleMinutes.custom {
                    // Applied on Return or when the field loses focus, not
                    // per keystroke: while you change 30 to 45, the field
                    // briefly holds "4", and a 4-minute timeout could stop
                    // an idle VM.
                    TextField("min", text: $form.customMinutes)
                        .textFieldStyle(.roundedBorder).frame(width: 52)
                        .multilineTextAlignment(.trailing)
                        .foregroundStyle(IdleMinutes.parse(form.customMinutes) == nil ? Color.red : .primary)
                        .accessibilityLabel("Auto-stop minutes")
                        .focused($minutesFocused)
                        .onSubmit { applyCustomIdle() }
                        .onChange(of: minutesFocused) { if !minutesFocused { applyCustomIdle() } }
                        .onDisappear { applyCustomIdle() }
                        .hint(Help.autoStopCustom)
                    Text("min").font(.caption).foregroundStyle(.secondary)
                    if IdleMinutes.commit(form.customMinutes, current: model.autoStopMinutes) != nil {
                        // Small, so the row still fits the popover's width.
                        Image(systemName: "return").font(.caption).foregroundStyle(.orange)
                            .hint("Press Return to apply the new time.")
                    }
                }
                Spacer(minLength: 0)
            }
            .disabled(!model.autoStop)
            .padding(.leading, 22)
            if model.autoStop, let since = model.idleSince {
                Text("Idle since \(since.formatted(date: .omitted, time: .shortened)); stops at \(since.addingTimeInterval(Double(model.autoStopMinutes * 60)).formatted(date: .omitted, time: .shortened)).")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Toggle(isOn: $model.hideIconWhenStopped) {
                Label("Hide menu bar icon while Colima is stopped", systemImage: "eye.slash")
            }
            .toggleStyle(.checkbox)
            .hint(Help.hideIcon)

            if model.profiles.count > 1 {
            Divider()
            SectionHeader(title: "Profiles", hint: Help.profiles) { EmptyView() }
            ForEach(model.profiles) { p in
                HStack(spacing: 8) {
                    Circle().fill(p.running ? Color.green : .secondary.opacity(0.5)).frame(width: 7, height: 7)
                    Text(p.name).font(.system(size: 12, weight: p.name == model.profile ? .semibold : .regular))
                    Text("\(p.cpus) CPU · \(p.memGB) GB").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if p.name != model.profile {
                        Button("Show") { model.profile = p.name }.controlSize(.mini)
                            .hint("Switch the dashboard to the \(p.name) profile.")
                    }
                }
            }
            }

            Divider()
            SectionHeader(title: "App")
            Toggle("Check for new versions daily", isOn: Binding(
                get: { Updater.shared.enabled }, set: { Updater.shared.enabled = $0 }))
                .hint(Help.checkUpdates)
            Toggle("Notify when a container crashes, OOMs or turns unhealthy", isOn: $model.notifyOnCrash)
                .hint(Help.notify)
            Toggle("Launch ColimaBar at login", isOn: Binding(get: { form.loginEnabled || form.loginNeedsApproval }, set: { on in
                do {
                    try LoginItem.set(on)
                } catch {
                    model.notify("Login item change failed: \(error.localizedDescription)")
                }
                form.loginEnabled = LoginItem.isEnabled
                form.loginNeedsApproval = false
            }))
            .hint(Help.login)
            if form.loginNeedsApproval {
                HStack(spacing: 6) {
                    Text("Waiting for your approval in System Settings > Login Items.")
                        .font(.caption2).foregroundStyle(.orange)
                    Button("Open") { SMAppService.openSystemSettingsLoginItems() }.controlSize(.mini)
                }
            }
        }
        .toggleStyle(.switch).controlSize(.small)
        .onAppear {
            syncPickers()
            syncIdle()
        }
        .onChange(of: model.vm) { syncPickers() }
    }

    private func dfHelp(_ type: String) -> String {
        switch type {
        case "Images": return Help.dfImages
        case "Containers": return Help.dfContainers
        case "Volumes": return Help.dfVolumes
        default: return Help.dfCache
        }
    }

    private func syncPickers() {
        form.cpu = model.vm.cpus
        form.mem = model.vm.memGB
        form.loginEnabled = LoginItem.isEnabled
        let enabled = form.loginEnabled
        Task {
            let pending = enabled ? await Task.detached { LoginItem.disabledInSettings() }.value : false
            form.loginNeedsApproval = pending
        }
    }

    /// Only on appear: a VM change must not replace minutes you are typing.
    private func syncIdle() {
        if !IdleMinutes.presets.contains(model.autoStopMinutes) {
            form.customIdle = true
            form.customMinutes = "\(model.autoStopMinutes)"
        }
    }

    /// A preset's minutes, or IdleMinutes.custom while the custom field shows.
    private var idleSelection: Binding<Int> {
        Binding(
            get: { form.customIdle || !IdleMinutes.presets.contains(model.autoStopMinutes)
                ? IdleMinutes.custom : model.autoStopMinutes },
            set: { v in
                if v == IdleMinutes.custom {
                    form.customIdle = true
                    form.customMinutes = "\(model.autoStopMinutes)"
                } else {
                    form.customIdle = false
                    model.autoStopMinutes = v
                }
            })
    }

    /// Applies the custom field. A preset picked after "Custom" wins: the
    /// field's focus loss and disappearance must not undo it.
    private func applyCustomIdle() {
        guard form.customIdle, let n = IdleMinutes.commit(form.customMinutes, current: model.autoStopMinutes) else { return }
        model.autoStopMinutes = n
    }
}

struct RouteRow: View {
    let ok: Bool
    let text: String
    let help: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: ok ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(ok ? Color.green : .secondary)
            Text(text).font(.caption)
        }
        .hint(help)
    }
}

struct Empty: View {
    let text: String
    var body: some View {
        Text(text).font(.callout).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity).padding(.vertical, 30)
    }
}
