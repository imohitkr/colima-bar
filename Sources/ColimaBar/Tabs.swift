import ServiceManagement
import SwiftUI

// MARK: - Containers

struct ContainersTab: View {
    let model: ColimaModel
    @Bindable var ui: ViewState

    var body: some View {
        let groups = grouped
        VStack(alignment: .leading, spacing: 6) {
            if groups.isEmpty {
                Empty(text: model.containers.isEmpty ? "No containers" : "No matches")
            }
            ForEach(groups, id: \.key) { g in
                let isCollapsed = Binding(
                    get: { ui.collapsed.contains(g.key) },
                    set: { if $0 { ui.collapsed.insert(g.key) } else { ui.collapsed.remove(g.key) } })
                SectionHeader(title: g.title, collapsed: isCollapsed) {
                    if let project = g.project {
                        IconButton("play.fill", "Start all in \(project)") { model.project(project, "start") }
                        IconButton("arrow.clockwise", "Restart all in \(project)") { model.project(project, "restart") }
                        IconButton("stop.fill", "Stop all in \(project)") { model.project(project, "stop") }
                    } else if g.key == "~standalone", model.running.count > 1 {
                        Button("Stop all") { model.ctl("stop-all") }.buttonStyle(.borderless).font(.caption)
                    }
                }
                if !isCollapsed.wrappedValue {
                    ForEach(g.items) { c in
                        ContainerRow(model: model, c: c, stat: model.stats[c.id])
                    }
                }
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

struct ContainerRow: View {
    let model: ColimaModel
    let c: Container
    let stat: Stat?

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(dot).frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(c.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                    if let h = c.health {
                        Text(h == "health: starting" ? "starting" : h)
                            .font(.system(size: 9, weight: .medium))
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(healthColor(h).opacity(0.15), in: Capsule())
                            .foregroundStyle(healthColor(h))
                    }
                }
                Text(c.isRunning ? c.image : "\(c.image) · \(c.status)")
                    .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 4)
            ForEach(c.ports.prefix(3), id: \.self) { p in
                Button(String(p)) { model.open(port: p) }
                    .buttonStyle(.plain)
                    .font(.system(size: 10, weight: .medium).monospacedDigit())
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(.blue.opacity(0.12), in: Capsule())
                    .foregroundStyle(.blue)
                    .help("Open http://localhost:\(p)")
            }
            if c.isRunning {
                // Fixed-width, right-aligned, monospaced: numbers tick in place.
                Text(stat.map { String(format: "%.1f%%", $0.cpu) } ?? "–")
                    .frame(width: 46, alignment: .trailing)
                Text(stat.map { Fmt.bytes($0.memBytes) } ?? "–")
                    .frame(width: 54, alignment: .trailing)
            }
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
                IconButton("text.alignleft", "Logs") { model.terminal("ctr-logs", c.name) }
                IconButton("chevron.left.forwardslash.chevron.right", "Shell") { model.terminal("ctr-shell", c.name) }
                IconButton("arrow.clockwise", "Restart") { model.container(c.id, "restart") }
                IconButton("stop.fill", "Stop") { model.container(c.id, "stop") }
            } else {
                IconButton("text.alignleft", "Logs") { model.terminal("ctr-logs", c.name) }
                IconButton("play.fill", "Start") { model.container(c.id, "start") }
                IconButton("trash", "Remove") { model.ctl("ctr-rm", c.name) }
            }
            Menu {
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

// MARK: - Images

struct ImagesTab: View {
    let model: ColimaModel
    let search: String

    var body: some View {
        let q = search.lowercased()
        let list = model.images.filter { q.isEmpty || $0.repo.lowercased().contains(q) || $0.tag.lowercased().contains(q) }
        let unused = model.images.filter { $0.containers == 0 }
        VStack(alignment: .leading, spacing: 6) {
            SectionHeader(title: "\(model.images.count) images · \(unused.count) unused") {
                Button("Remove dangling") { model.ctl("prune", "dangling") }.buttonStyle(.borderless).font(.caption)
                Button("Remove unused") { model.ctl("prune", "images") }.buttonStyle(.borderless).font(.caption)
            }
            if list.isEmpty { Empty(text: model.images.isEmpty ? "No images" : "No matches") }
            ForEach(list) { i in
                HStack(spacing: 8) {
                    Image(systemName: i.dangling ? "square.dashed" : "square.stack.3d.up")
                        .foregroundStyle(.secondary).frame(width: 16)
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
                    }
                    Text(Fmt.bytes(i.size)).font(.system(size: 11).monospacedDigit())
                        .frame(width: 60, alignment: .trailing)
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
        VStack(alignment: .leading, spacing: 6) {
            SectionHeader(title: "\(model.volumes.count) volumes · \(unused.count) unused") {
                Button("Remove unused") { model.ctl("prune", "volumes") }.buttonStyle(.borderless).font(.caption)
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
    var loginEnabled = SMAppService.mainApp.status == .enabled
}

struct SystemTab: View {
    @Bindable var model: ColimaModel
    @Bindable var form: SystemForm

    private let presets = [("Light", 2, 4), ("Standard", 4, 8), ("Heavy", 8, 16)]
    private let cpuOpts = [2, 4, 6, 8, 10, 12]
    private let memOpts = [4, 8, 12, 16, 24, 32]

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
                }
            }
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
                GridRow {
                    Text("CPU").font(.caption).foregroundStyle(.secondary)
                    Picker("", selection: $form.cpu) { ForEach(cpuOpts, id: \.self) { Text("\($0)").tag($0) } }
                        .pickerStyle(.segmented).labelsHidden()
                }
                GridRow {
                    Text("Memory").font(.caption).foregroundStyle(.secondary)
                    Picker("", selection: $form.mem) { ForEach(memOpts, id: \.self) { Text("\($0) GB").tag($0) } }
                        .pickerStyle(.segmented).labelsHidden()
                }
            }
            HStack {
                Text("Applying restarts the VM; running containers stop.")
                    .font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Button("Apply") { model.ctl("resources", "\(form.cpu)", "\(form.mem)") }
                    .disabled(form.cpu == model.vm.cpus && form.mem == model.vm.memGB)
            }

            Divider()
            SectionHeader(title: "Features")
            Toggle(isOn: Binding(get: { model.rosetta }, set: { model.ctl("rosetta", $0 ? "on" : "off") })) {
                Label("Rosetta (amd64 emulation)", systemImage: "cpu")
            }
            Toggle(isOn: Binding(get: { model.k8s }, set: { model.ctl("k8s", $0 ? "on" : "off") })) {
                Label("Kubernetes (k3s) · context: colima", systemImage: "circle.hexagongrid")
            }
            HStack {
                Label("Disk: \(model.vm.diskGB) GB", systemImage: "internaldrive")
                Spacer()
                ForEach([150, 200, 300].filter { $0 > model.vm.diskGB }, id: \.self) { d in
                    Button("\(d) GB") { model.ctl("disk", "\(d)") }.controlSize(.small)
                }
            }
            Text("Disks can only grow, not shrink.").font(.caption2).foregroundStyle(.secondary)

            Divider()
            SectionHeader(title: "Disk usage")
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                GridRow {
                    Text("Type"); Text("Count"); Text("Size"); Text("Reclaimable")
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
                }
            }
            HStack(spacing: 6) {
                Button("Dangling + build cache") { model.ctl("prune", "dangling") }
                Button("Unused images") { model.ctl("prune", "images") }
                Button("Unused volumes") { model.ctl("prune", "volumes") }
                Button("Full cleanup") { model.ctl("prune", "all") }
            }
            .controlSize(.small)

            Divider()
            SectionHeader(title: "App")
            Toggle("Notify when a container crashes, OOMs or turns unhealthy", isOn: $model.notifyOnCrash)
            Toggle("Launch ColimaBar at login", isOn: Binding(get: { form.loginEnabled }, set: { on in
                do {
                    if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                } catch {
                    model.notify("Login item change failed: \(error.localizedDescription)")
                }
                form.loginEnabled = SMAppService.mainApp.status == .enabled
            }))
        }
        .toggleStyle(.switch).controlSize(.small)
        .onAppear { syncPickers() }
        .onChange(of: model.vm) { syncPickers() }
    }

    private func syncPickers() {
        form.cpu = model.vm.cpus
        form.mem = model.vm.memGB
        form.loginEnabled = SMAppService.mainApp.status == .enabled
    }
}

struct Empty: View {
    let text: String
    var body: some View {
        Text(text).font(.callout).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity).padding(.vertical, 30)
    }
}
