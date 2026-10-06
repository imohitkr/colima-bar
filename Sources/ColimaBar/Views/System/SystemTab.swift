import ServiceManagement
import SwiftUI

struct SystemTab: View {
    @Bindable var model: ColimaModel
    @Bindable var form: SystemForm
    @FocusState private var minutesFocused: Bool

    /// A one-click VM size.
    private struct ResourcePreset {
        let name: String
        let cpus: Int
        let memGB: Int
    }

    private let presets = [
        ResourcePreset(name: "Light", cpus: 2, memGB: 4),
        ResourcePreset(name: "Standard", cpus: 4, memGB: 8),
        ResourcePreset(name: "Heavy", cpus: 8, memGB: 16),
    ]
    static let cpuOpts = [2, 4, 6, 8, 10, 12]
    static let memOpts = [4, 8, 12, 16, 24, 32]

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
                ForEach(presets, id: \.name) { p in
                    let active = p.cpus == model.vm.cpus && p.memGB == model.vm.memGB
                    Button {
                        model.run(.resources, "\(p.cpus)", "\(p.memGB)")
                    } label: {
                        VStack(spacing: 1) {
                            Text(p.name).font(.system(size: 11, weight: .semibold))
                            Text("\(p.cpus) CPU · \(p.memGB) GB").font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 5)
                        .background(
                            active ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.08),
                            in: RoundedRectangle(cornerRadius: 6)
                        )
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(active ? Color.accentColor : .clear))
                    }
                    .buttonStyle(.plain).disabled(active)
                    .hint(Help.presets)
                }
            }
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
                GridRow {
                    Text("CPU").font(.caption).foregroundStyle(.secondary)
                    Picker("", selection: $form.cpu) {
                        ForEach(Self.options(Self.cpuOpts, model.vm.cpus, form.cpu), id: \.self) {
                            Text("\($0)").tag($0)
                        }
                    }
                    .pickerStyle(.segmented).labelsHidden()
                    .hint(Help.cpu)
                }
                GridRow {
                    Text("Memory").font(.caption).foregroundStyle(.secondary)
                    Picker("", selection: $form.mem) {
                        ForEach(Self.options(Self.memOpts, model.vm.memGB, form.mem), id: \.self) {
                            Text("\($0) GB").tag($0)
                        }
                    }
                    .pickerStyle(.segmented).labelsHidden()
                    .hint(Help.memory)
                }
            }
            HStack {
                Text("Applying restarts the VM; running containers stop.")
                    .font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Button("Apply") { model.run(.resources, "\(form.cpu)", "\(form.mem)") }
                    .disabled(form.cpu == model.vm.cpus && form.mem == model.vm.memGB)
                    .hint(Help.apply)
            }

            Divider()
            SectionHeader(title: "Features")
            Toggle(isOn: Binding(get: { model.isRosettaEnabled }, set: { model.run(.rosetta, $0 ? "on" : "off") })) {
                Label("Rosetta (amd64 emulation)", systemImage: "cpu")
            }
            .hint(Help.rosetta)
            Toggle(isOn: Binding(get: { model.isKubernetesEnabled }, set: { model.run(.k8s, $0 ? "on" : "off") })) {
                Label("Kubernetes (k3s) · context: \(model.kubeContext)", systemImage: "circle.hexagongrid")
            }
            .hint(Help.k8s)
            HStack {
                Label("Disk: \(model.vm.diskGB) GB", systemImage: "internaldrive")
                Spacer()
                ForEach([150, 200, 300].filter { $0 > model.vm.diskGB }, id: \.self) { d in
                    Button("\(d) GB") { model.run(.disk, "\(d)") }.controlSize(.small)
                }
            }
            .hint(Help.disk)
            Text("Disks can only grow, not shrink.").font(.caption2).foregroundStyle(.secondary)

            Divider()
            SectionHeader(title: "Disk usage")
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                GridRow {
                    Text("Type")
                    Text("Count")
                    Text("Size")
                    Text("Reclaimable").hint(Help.dfReclaimable)
                }
                .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(model.df) { r in
                    GridRow {
                        Text(r.type)
                        Text("\(r.count)").gridColumnAlignment(.trailing)
                        Text(ByteFormat.bytes(r.size)).gridColumnAlignment(.trailing)
                        Text(ByteFormat.bytes(r.reclaimable)).gridColumnAlignment(.trailing)
                            .foregroundStyle(r.reclaimable > 0 ? .orange : .secondary)
                    }
                    .font(.system(size: 11).monospacedDigit())
                    .hint(dfHelp(r.type))
                }
            }
            HStack(spacing: 6) {
                Button("Dangling + build cache") { model.run(.prune, "dangling") }.hint(Help.pruneDangling)
                Button("Unused images") { model.run(.prune, "images") }.hint(Help.pruneImages)
                Button("Unused volumes") { model.run(.prune, "volumes") }.hint(Help.pruneVolumes)
                Button("Full cleanup") { model.run(.prune, "all") }.hint(Help.pruneAll)
            }
            .controlSize(.small)

            Divider()
            SectionHeader(title: "Auto-start & auto-stop")
            Toggle(isOn: $model.autoStart) {
                Label("Start Colima when something uses docker", systemImage: "bolt.badge.automatic")
            }
            .hint(Help.autoStart)
            VStack(alignment: .leading, spacing: 3) {
                RouteRow(
                    ok: model.routing.context, text: "docker context: \(Routing.contextName)", help: Help.routeContext)
                RouteRow(
                    ok: model.routing.launchd, text: "Apps & IDE test runners (launchd DOCKER_HOST)",
                    help: Help.routeLaunchd)
                RouteRow(
                    ok: model.routing.testcontainers, text: "testcontainers (~/.testcontainers.properties)",
                    help: Help.routeTestcontainers)
                HStack {
                    RouteRow(ok: model.routing.varRun, text: "/var/run/docker.sock", help: Help.routeVarRun)
                    if !model.routing.varRun {
                        Button(form.isLinking ? "Linking…" : "Link (admin)") {
                            form.isLinking = true
                            Task {
                                if !(await Routing.linkVarRun()) { model.notify("Couldn't link /var/run/docker.sock") }
                                await model.refreshRouting()
                                form.isLinking = false
                            }
                        }
                        .controlSize(.mini).disabled(form.isLinking)
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
                Text(
                    "Idle since \(since.formatted(date: .omitted, time: .shortened)); stops at \(since.addingTimeInterval(Double(model.autoStopMinutes * 60)).formatted(date: .omitted, time: .shortened))."
                )
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
                        Circle().fill(p.isRunning ? Color.green : .secondary.opacity(0.5)).frame(width: 7, height: 7)
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
            Toggle(
                "Check for new versions daily",
                isOn: Binding(
                    get: { Updater.shared.enabled }, set: { Updater.shared.enabled = $0 })
            )
            .hint(Help.checkUpdates)
            Toggle("Notify when a container crashes, OOMs or turns unhealthy", isOn: $model.notifyOnCrash)
                .hint(Help.notify)
            Toggle(
                "Launch ColimaBar at login",
                isOn: Binding(
                    get: { form.loginEnabled || form.loginNeedsApproval },
                    set: { on in
                        do {
                            try LoginItem.set(on)
                        } catch {
                            model.notify("Login item change failed: \(error.localizedDescription)")
                        }
                        form.loginEnabled = LoginItem.isEnabled
                        form.loginNeedsApproval = false
                    })
            )
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
            form.isCustomIdle = true
            form.customMinutes = "\(model.autoStopMinutes)"
        }
    }

    /// A preset's minutes, or IdleMinutes.custom while the custom field shows.
    private var idleSelection: Binding<Int> {
        Binding(
            get: {
                form.isCustomIdle || !IdleMinutes.presets.contains(model.autoStopMinutes)
                    ? IdleMinutes.custom : model.autoStopMinutes
            },
            set: { v in
                if v == IdleMinutes.custom {
                    form.isCustomIdle = true
                    form.customMinutes = "\(model.autoStopMinutes)"
                } else {
                    form.isCustomIdle = false
                    model.autoStopMinutes = v
                }
            })
    }

    /// Applies the custom field. A preset picked after "Custom" wins: the
    /// field's focus loss and disappearance must not undo it.
    private func applyCustomIdle() {
        guard form.isCustomIdle, let n = IdleMinutes.commit(form.customMinutes, current: model.autoStopMinutes) else {
            return
        }
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
