import SwiftUI

struct HeaderView: View {
    let model: ColimaModel

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(color.opacity(0.18)).frame(width: 34, height: 34)
                Image(systemName: "shippingbox.fill").foregroundStyle(color)
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("Colima").font(.headline)
                    // It also creates profiles, so it shows whenever Colima is installed.
                    if model.state != .notInstalled { ProfileMenu(model: model) }
                    if let busy = model.busy {
                        ProgressView().controlSize(.mini)
                        Text(busy + "…").font(.caption).foregroundStyle(.orange)
                    } else {
                        Text(stateText).font(.caption).foregroundStyle(color)
                    }
                }
                Text(subtitle).font(.caption).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
                    .hint(Help.subtitle)
            }
            Spacer()
            if model.state == .running {
                IconButton("arrow.clockwise", Help.restart) { model.run(.restart) }
                IconButton("stop.fill", Help.stopVM) { model.run(.stop) }
            } else if model.state == .stopped {
                IconButton("play.fill", Help.startVM) { model.run(.start) }
            }
        }
        .disabled(model.busy != nil)
        .padding(.horizontal, 12).padding(.vertical, 10)
    }

    private var color: Color {
        if model.busy != nil { return .orange }
        switch model.state {
        case .running: return .green
        case .stopped: return .secondary
        case .unknown, .notInstalled: return .secondary
        }
    }

    private var stateText: String {
        switch model.state {
        case .running: return "Running"
        case .stopped: return "Stopped"
        case .unknown: return "Checking…"
        case .notInstalled: return "Not installed"
        }
    }

    private var subtitle: String {
        guard model.state == .running else { return "profile: \(model.profile)" }
        let v = model.vm
        var parts = ["\(v.cpus) CPU", "\(ByteFormat.gibText(v.memGB)) GB", "\(v.diskGB) GB disk", v.arch]
        if !v.mountType.isEmpty { parts.append(v.mountType) }
        if model.isRosettaEnabled { parts.append("rosetta") }
        if model.isKubernetesEnabled { parts.append("k3s") }
        return parts.joined(separator: " · ")
    }
}

/// Header chip that shows the selected profile. Its menu switches between
/// profiles, starts and stops profiles, and creates and deletes profiles.
struct ProfileMenu: View {
    let model: ColimaModel

    var body: some View {
        Menu {
            Section("Show") {
                ForEach(model.profiles) { p in
                    Button {
                        model.profile = p.name
                    } label: {
                        Text("\(p.name == model.profile ? "✓ " : "")\(p.name)  ·  \(status(p))")
                    }
                }
                ForEach(pendingNew, id: \.self) { name in
                    Text("\(name)  ·  \(model.profileActions[name] ?? "")…")
                }
                if model.profiles.isEmpty && pendingNew.isEmpty { Text("No profiles yet") }
            }
            Divider()
            // A disabled submenu still opens on macOS, so leave out an empty one.
            let startable = model.profiles.filter { model.canStart(profile: $0.name) }
            let stoppable = model.profiles.filter { model.canStop(profile: $0.name) }
            if !startable.isEmpty {
                Menu("Start") {
                    ForEach(startable) { p in
                        Button(p.name) { model.startProfile(p.name) }
                    }
                }
            }
            if !stoppable.isEmpty {
                Menu("Stop") {
                    ForEach(stoppable) { p in
                        Button(p.name) { model.stopProfile(p.name) }
                    }
                }
            }
            Divider()
            Button("New Profile…") {
                let defaults = NewProfileForm.defaults(from: model.vm)
                model.dismissPopover()
                if let form = NewProfileAlert.run(defaults: defaults, existing: model.profiles.map(\.name)) {
                    model.createProfile(form)
                }
            }
            if !deletable.isEmpty {
                Menu("Delete Profile") {
                    ForEach(deletable) { p in
                        let running = model.isRunning(profile: p.name)
                        let refusal = ProfileDelete.refusal(
                            profile: p.name, selected: model.profile, isRunning: running)
                        Button(refusal == nil ? "\(p.name)…" : "\(p.name) (stop it first)") {
                            model.dismissPopover()
                            if DeleteProfileAlert.confirm(profile: p.name, isRunning: running) {
                                model.deleteProfile(p.name)
                            }
                        }
                        .disabled(refusal != nil)
                    }
                }
            }
        } label: {
            HStack(spacing: 2) {
                Text(model.profile)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
            }
            .font(.caption.weight(.medium))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(.quaternary.opacity(0.6), in: Capsule())
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .hint(Help.profile)
    }

    /// "running", "stopped", or the action that runs for the profile.
    /// The selected profile uses its live state, like Start and Stop.
    private func status(_ p: ProfileRow) -> String {
        if p.name == model.profile {
            if let busy = model.busy { return busy.lowercased() + "…" }
            return model.state == .running ? "running" : "stopped"
        }
        if let action = model.profileActions[p.name] { return action.lowercased() + "…" }
        return p.isRunning ? "running" : "stopped"
    }

    /// Profiles with no action that runs now. An action of the selected
    /// profile shows in `busy`, of the others in `profileActions`.
    private var deletable: [ProfileRow] {
        model.profiles.filter {
            model.profileActions[$0.name] == nil && !($0.name == model.profile && model.busy != nil)
        }
    }

    /// Profiles that New Profile creates now: `colima list` shows them
    /// only after the VM exists.
    private var pendingNew: [String] {
        model.profileActions.keys.filter { name in !model.profiles.contains { $0.name == name } }.sorted()
    }
}
