import SwiftUI

/// The VM settings page. It replaces the tabs and the stopped screen between
/// the header and the hint bar, so the popover keeps its fixed size. It edits
/// the keys of colima.yaml that the other controls do not cover.
struct VMConfigView: View {
    let model: ColimaModel
    @Bindable var ui: ViewState
    @Bindable private var form: VMConfigForm

    init(model: ColimaModel, ui: ViewState) {
        self.model = model
        self.ui = ui
        form = ui.vmConfig
    }

    private var running: Bool { model.state == .running }
    private var read: VMSettings.Read { form.baseline }

    private var context: VMSettingsCheck.Context {
        var c = VMSettingsCheck.Context()
        c.current = read
        return c
    }

    private var problems: [String] { VMSettingsCheck.problems(form.change, context: context) }

    private var canApply: Bool {
        VMConfigForm.canApply(
            isDirty: form.isDirty, problems: problems, busy: model.busy != nil, isDebug: model.isDebug,
            hasFile: model.vmSettings != nil)
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider()
            VMRecreateNotice(model: model).padding(.horizontal, 12).padding(.top, 6)
            ScrollView {
                if model.vmSettings == nil {
                    Text("This profile has no colima.yaml. Start it once to create one.")
                        .font(.caption).foregroundStyle(.secondary)
                        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        network
                        Divider()
                        mounts
                        Divider()
                        registries
                        Divider()
                        VMTypeSection(model: model, form: form)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .disabled(model.busy != nil)
                }
            }
            .scrollIndicators(.automatic)
            Divider()
            bottomBar
        }
        .task(id: model.profile) { sync() }
        .onChange(of: model.vmSettings) { sync() }
        .onChange(of: model.vmSettingsSHA) { sync() }
    }

    /// Shows colima.yaml. It keeps your edits while they differ from the
    /// file, and drops them for another profile.
    private func sync() {
        guard let now = model.vmSettings else { return }
        if form.shouldReload(for: now, profile: model.profile) {
            form.load(now, sha: model.vmSettingsSHA, profile: model.profile)
        }
    }

    /// Applies the edits. After an apply, or if the file has these values
    /// already or changed outside ColimaBar, the page shows the file again.
    private func apply() {
        let change = form.change
        let profile = model.profile
        let sha = form.baselineSHA
        Task {
            let outcome = await model.applyVMSettings(change, profile: profile, baselineSHA: sha)
            guard outcome.reloadsForm, model.profile == profile, let now = model.vmSettings else { return }
            form.load(now, sha: model.vmSettingsSHA, profile: profile)
        }
    }

    // MARK: Parts

    private var topBar: some View {
        HStack(spacing: 8) {
            Text("VM settings · profile \(model.profile)").font(.headline)
            Spacer()
            Button("Done") { ui.showVMConfig = false }
                .hint(Help.vmSettingsDone)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private var network: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Network")
            VStack(alignment: .leading, spacing: 2) {
                Text("DNS servers").font(.caption).foregroundStyle(.secondary)
                TextField("Colima default", text: $form.dnsText)
                    .textFieldStyle(.roundedBorder)
                    .disabled(!read.isEditable(.dnsServers))
                    .accessibilityLabel("DNS servers")
                    .hint(Help.dnsServers)
                note(.dnsServers, "network.dns", "Up to 3 IP addresses. Empty uses the DNS of your Mac.")
            }
            Toggle(isOn: $form.address) {
                Label("Reachable IP address", systemImage: "network")
            }
            .disabled(!read.isEditable(.address) || !read.usesVZ || read.address)
            .hint(Help.vmAddress)
            if !read.isEditable(.address) {
                readOnlyText("network.address")
            } else if !read.usesVZ {
                caption("This needs the vz VM type.")
            } else if read.address {
                caption("Colima cannot turn off the address of this VM.")
            }
            if running, read.address, !model.vm.ipAddress.isEmpty {
                HStack(spacing: 6) {
                    Text("VM IP: \(model.vm.ipAddress)").font(.caption).textSelection(.enabled)
                    IconButton("doc.on.doc", Help.vmCopyIP) { Pasteboard.copy(model.vm.ipAddress) }
                }
                .padding(.leading, 22)
            }
            HStack(spacing: 8) {
                Text("Port forwarder").font(.caption).foregroundStyle(.secondary)
                Picker("Port forwarder", selection: $form.portForwarder) {
                    ForEach(Self.forwarders(including: read.portForwarder), id: \.self) { Text($0).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden()
                .disabled(!read.isEditable(.portForwarder))
                .hint(Help.portForwarder)
            }
            if !read.isEditable(.portForwarder) {
                readOnlyText("portForwarder")
            } else {
                caption("grpc also forwards UDP. It is experimental.")
            }
        }
        .toggleStyle(.switch).controlSize(.small)
    }

    private var mounts: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionHeader(title: "Mounts", hint: Help.mounts) { EmptyView() }
            if form.mounts.isEmpty {
                caption(form.emptyListMountsHome ? "Colima mounts your home folder." : "No folders are mounted.")
            }
            ForEach(Array(form.mounts.enumerated()), id: \.offset) { index, _ in
                VMMountRow(
                    mount: Binding(
                        get: { form.mounts.indices.contains(index) ? form.mounts[index] : VMMount(location: "") },
                        set: { if form.mounts.indices.contains(index) { form.mounts[index] = $0 } }),
                    enabled: read.isEditable(.mounts), remove: { form.removeMount(at: index) })
            }
            HStack {
                Button("Add Folder…") { addFolder() }
                    .disabled(!read.isEditable(.mounts))
                    .hint(Help.mountAdd)
                Spacer()
            }
            if !read.isEditable(.mounts) {
                readOnlyText("mounts")
            } else {
                caption("With a list, Colima mounts only these folders. Keep ~ to mount your home folder.")
            }
            Toggle("Send file changes to the VM (inotify)", isOn: $form.mountInotify)
                .toggleStyle(.checkbox)
                .disabled(!read.isEditable(.mountInotify))
                .hint(Help.mountInotify)
            caption("Experimental.", indent: 20)
        }
    }

    private var registries: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionHeader(title: "Docker registries")
            registryField(
                "Mirrors", text: $form.mirrorsText, field: .registryMirrors, key: "docker.registry-mirrors",
                hint: Help.registryMirrors)
            registryField(
                "Insecure registries", text: $form.insecureText, field: .insecureRegistries,
                key: "docker.insecure-registries", hint: Help.insecureRegistries)
            if !read.usesDocker { caption("Registries need the docker runtime.") }
        }
    }

    private func registryField(
        _ title: String, text: Binding<String>, field: VMSettings.Field, key: String, hint text2: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            TextField("None", text: text)
                .textFieldStyle(.roundedBorder)
                .disabled(!read.isEditable(field) || !read.usesDocker)
                .accessibilityLabel(title)
                .hint(text2)
            if !read.isEditable(field) { readOnlyText(key) }
        }
    }

    private var bottomBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(problems, id: \.self) { Text($0).font(.caption).foregroundStyle(.red) }
            HStack(spacing: 8) {
                Text(
                    running
                        ? "Applying restarts the VM. Running containers stop."
                        : "The VM stays stopped. Changes apply at the next start."
                )
                .font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button("Revert") { form.revert() }
                    .disabled(!form.isDirty)
                    .hint(Help.vmSettingsRevert)
                Button("Apply") { apply() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canApply)
                    .hint(
                        model.isDebug
                            ? Help.doctorDebug : (running ? Help.vmSettingsApply : Help.vmSettingsApplyWhenStopped))
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    // MARK: Helpers

    private func caption(_ text: String, indent: CGFloat = 0) -> some View {
        Text(text).font(.caption2).foregroundStyle(.secondary).padding(.leading, indent)
    }

    private func readOnlyText(_ key: String) -> some View {
        caption(ColimaYAML.Failure.unsupported(key).errorDescription ?? "")
    }

    @ViewBuilder
    private func note(_ field: VMSettings.Field, _ key: String, _ text: String) -> some View {
        if read.isEditable(field) { caption(text) } else { readOnlyText(key) }
    }

    /// The folder panel. The popover closes first, so it does not cover the
    /// panel. The form keeps its edits.
    private func addFolder() {
        model.dismissPopover()
        let panel = NSOpenPanel()
        panel.title = "Add Folder"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        form.addMount(Self.abbreviated(url.path, home: Paths.home))
    }

    /// The port forwarders to pick, and the one that the file has if it is another.
    static func forwarders(including current: String) -> [String] {
        ["ssh", "grpc"].contains(current) ? ["ssh", "grpc"] : ["ssh", "grpc", current]
    }

    /// A path in your home folder starts with `~`, as in colima.yaml.
    static func abbreviated(_ path: String, home: String) -> String {
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }
}
