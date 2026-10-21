import SwiftUI

/// The VM type and the mount type of the profile. Colima fixes both when it
/// creates the VM, so a change deletes the VM and creates it again (see
/// `VMRecreateFlow`). The pick is not part of Apply: **Change and Recreate…**
/// has its own confirmation.
struct VMTypeSection: View {
    let model: ColimaModel
    @Bindable var form: VMConfigForm

    private var read: VMSettings.Read { form.baseline }
    private var current: (vmType: String, mountType: String) {
        VMTypeRules.effective(vmType: read.vmType, mountType: read.mountType)
    }

    private var changed: Bool { form.vmType != current.vmType || form.mountType != current.mountType }

    private var problems: [String] {
        guard changed else { return [] }
        return VMSettingsCheck.recreateProblems(
            vmType: form.vmType, mountType: form.mountType,
            context: .init(current: read, qemuInstalled: VMTypeRules.qemuInstalled(arch: read.arch)))
    }

    private var canRecreate: Bool {
        changed && problems.isEmpty && model.canRecreate && !form.isDirty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionHeader(title: "VM type and mount type", hint: Help.vmTypeSection) { EmptyView() }
            picker("VM type", selection: $form.vmType, options: vmTypes, hint: Help.vmTypePicker)
            picker("Mount type", selection: $form.mountType, options: mountTypes, hint: Help.mountTypePicker)
            Text("Arch: \(shown(read.arch, "host")) · Runtime: \(shown(read.runtime, "docker"))")
                .font(.caption)
            ForEach(problems, id: \.self) { Text($0).font(.caption).foregroundStyle(.red) }
            Text("A change deletes the VM and creates it again. ColimaBar can back up first.")
                .font(.caption2).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Change and Recreate…") { recreate() }
                    .disabled(!canRecreate)
                    .hint(model.recreateBlockReason ?? Help.vmRecreate)
            }
        }
        .onChange(of: form.vmType) {
            if !VMTypeRules.isValid(vmType: form.vmType, mountType: form.mountType) {
                form.mountType = VMTypeRules.defaultMountType(for: form.vmType)
            }
        }
    }

    /// vz and qemu, and the type that the file has if it is another one (krunkit).
    private var vmTypes: [String] {
        VMTypeRules.vmTypes.contains(current.vmType) ? VMTypeRules.vmTypes : VMTypeRules.vmTypes + [current.vmType]
    }

    private var mountTypes: [String] {
        var out = VMTypeRules.mountTypes(for: form.vmType)
        if form.vmType == current.vmType, !current.mountType.isEmpty, !out.contains(current.mountType) {
            out.append(current.mountType)
        }
        return out
    }

    private func picker(_ title: String, selection: Binding<String>, options: [String], hint text: String)
        -> some View
    {
        HStack(spacing: 8) {
            Text(title).font(.caption).foregroundStyle(.secondary).frame(width: 70, alignment: .leading)
            Picker(title, selection: selection) {
                ForEach(options, id: \.self) { Text($0).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden()
            .hint(text)
        }
    }

    private func shown(_ value: String, _ fallback: String) -> String { value.isEmpty ? fallback : value }

    /// The typed confirmation comes first. Only then does colima-ctl.sh run
    /// (it asks one more time). If the selected profile changed meanwhile, it stops.
    private func recreate() {
        let p = model.profile
        let (vmType, mountType) = (form.vmType, form.mountType)
        model.dismissPopover()
        guard let choice = VMRecreateAlert.confirm(model: model, vmType: vmType, mountType: mountType),
            p == model.profile
        else { return }
        model.startRecreate(
            vmType: vmType, mountType: mountType, backUp: choice.backUp, saveImages: choice.saveImages,
            parent: choice.parent)
    }
}
