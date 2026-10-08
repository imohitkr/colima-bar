import SwiftUI

/// The "VM resources" and "Features" sections. The System tab shows them
/// for a running VM, and the stopped screen for a stopped VM. A running VM
/// restarts for a change. A stopped VM only gets the new values in
/// colima.yaml, and they apply at the next start.
struct VMSettingsSection: View {
    @Bindable var model: ColimaModel
    @Bindable var form: SystemForm
    /// The VM state of the selected profile.
    let running: Bool

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

    /// The values that the controls show: live for a running VM, else
    /// from colima.yaml.
    private var shown: VMConfig.Shown {
        VMConfig.shown(running: running, vm: model.vm, config: model.config)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "VM resources")
            HStack(spacing: 6) {
                ForEach(presets, id: \.name) { p in
                    let active = p.cpus == shown.cpus && p.memGB == shown.memGB
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
                    .hint(running ? Help.presets : Help.presetsWhenStopped)
                }
            }
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
                GridRow {
                    Text("CPU").font(.caption).foregroundStyle(.secondary)
                    Picker("", selection: $form.cpu) {
                        ForEach(Self.options(Self.cpuOpts, shown.cpus, form.cpu), id: \.self) {
                            Text("\($0)").tag($0)
                        }
                    }
                    .pickerStyle(.segmented).labelsHidden()
                    .hint(Help.cpu)
                }
                GridRow {
                    Text("Memory").font(.caption).foregroundStyle(.secondary)
                    Picker("", selection: $form.mem) {
                        ForEach(Self.options(Self.memOpts, shown.memGB, form.mem), id: \.self) {
                            Text("\($0) GB").tag($0)
                        }
                    }
                    .pickerStyle(.segmented).labelsHidden()
                    .hint(Help.memory)
                }
            }
            HStack {
                Text(
                    running
                        ? "Applying restarts the VM; running containers stop."
                        : "The VM stays stopped. Changes apply at the next start."
                )
                .font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Button("Apply") { model.run(.resources, "\(form.cpu)", "\(form.mem)") }
                    .disabled(form.cpu == shown.cpus && form.mem == shown.memGB)
                    .hint(running ? Help.apply : Help.applyWhenStopped)
            }

            Divider()
            SectionHeader(title: "Features")
            // The toggles show colima.yaml. After a change, the next refresh
            // reads the saved value.
            Toggle(isOn: Binding(get: { shown.rosetta }, set: { model.run(.rosetta, $0 ? "on" : "off") })) {
                Label("Rosetta (amd64 emulation)", systemImage: "cpu")
            }
            // A switch that is on stays usable, so you can turn Rosetta off.
            .disabled(!shown.rosettaSupported && !shown.rosetta)
            .hint(shown.rosettaSupported ? (running ? Help.rosetta : Help.rosettaWhenStopped) : Help.rosettaNeedsVZ)
            if !shown.rosettaSupported {
                Text("Rosetta needs the vz VM type.")
                    .font(.caption2).foregroundStyle(.secondary)
                    .padding(.leading, 22)
            }
            Toggle(isOn: Binding(get: { shown.kubernetes }, set: { model.run(.k8s, $0 ? "on" : "off") })) {
                Label("Kubernetes (k3s) · context: \(model.kubeContext)", systemImage: "circle.hexagongrid")
            }
            .hint(running ? Help.k8s : Help.k8sWhenStopped)
            HStack {
                Label("Disk: \(shown.diskGB) GB", systemImage: "internaldrive")
                Spacer()
                ForEach([150, 200, 300].filter { $0 > shown.diskGB }, id: \.self) { d in
                    Button("\(d) GB") { model.run(.disk, "\(d)") }.controlSize(.small)
                }
                let smaller = DiskShrink.options(current: shown.diskGB)
                if !smaller.isEmpty {
                    Menu("Shrink…") {
                        ForEach(smaller, id: \.self) { d in
                            Button("\(d) GB") { shrinkDisk(to: d, from: shown.diskGB, kubernetes: shown.kubernetes) }
                        }
                    }
                    .menuStyle(.borderlessButton).fixedSize().controlSize(.small)
                    .hint(running ? Help.diskShrink : Help.diskShrinkWhenStopped)
                }
            }
            .hint(running ? Help.disk : Help.diskWhenStopped)
            Text(
                running
                    ? "A disk grows in place. Shrink deletes all images, containers and volumes."
                    : "The disk grows at the next start. Shrink deletes all images, containers and volumes."
            )
            .font(.caption2).foregroundStyle(.secondary)
        }
        .toggleStyle(.switch).controlSize(.small)
        .onAppear { syncPickers() }
        // Only when the shown CPU or memory changes: a VM fact such as the
        // driver, or a change of Rosetta, Kubernetes or the disk, must not
        // undo a value that you picked.
        .onChange(of: [shown.cpus, shown.memGB]) { syncPickers() }
    }

    /// The typed confirmation comes first. Only then does colima-ctl.sh run
    /// (it asks one more time). The action goes to the profile that the
    /// confirmation named. If the selected profile changed meanwhile, it stops.
    private func shrinkDisk(to size: Int, from: Int, kubernetes: Bool) {
        let p = model.profile
        guard DiskShrink.isValid(size, current: from) else { return }
        // The popover would cover the alert.
        model.dismissPopover()
        guard
            ShrinkDiskAlert.confirm(
                profile: p, from: from, to: size, usage: model.df, kubernetes: kubernetes, running: running),
            p == model.profile
        else { return }
        model.run(.diskShrink, "\(size)", profile: p)
    }

    private func syncPickers() {
        let s = shown
        form.cpu = s.cpus
        form.mem = s.memGB
    }
}
