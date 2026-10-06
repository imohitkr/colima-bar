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
                    // Only worth showing once there's more than one profile.
                    if model.profiles.count > 1 { ProfileMenu(model: model) }
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
        var parts = ["\(v.cpus) CPU", "\(v.memGB) GB", "\(v.diskGB) GB disk", v.arch]
        if !v.mountType.isEmpty { parts.append(v.mountType) }
        if model.isRosettaEnabled { parts.append("rosetta") }
        if model.isKubernetesEnabled { parts.append("k3s") }
        return parts.joined(separator: " · ")
    }
}

/// Header chip that shows the selected profile and switches between them.
struct ProfileMenu: View {
    let model: ColimaModel

    var body: some View {
        Menu {
            ForEach(model.profiles) { p in
                Button {
                    model.profile = p.name
                } label: {
                    Text("\(p.name == model.profile ? "✓ " : "")\(p.name)  ·  \(p.isRunning ? "running" : "stopped")")
                }
            }
            if model.profiles.isEmpty { Text("No profiles yet") }
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
}
