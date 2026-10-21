import SwiftUI

struct ContainerRow: View {
    let model: ColimaModel
    let ui: ViewState
    let c: Container

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(dot).frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    // Middle truncation keeps suffixes like "-1" visible.
                    inspectTarget(
                        Text(c.name).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle))
                    if let h = c.health {
                        Text(h == "health: starting" ? "starting" : h)
                            .font(.system(size: 9, weight: .medium))
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(healthColor(h).opacity(0.15), in: Capsule())
                            .foregroundStyle(healthColor(h))
                            .hint(h == "healthy" ? Help.healthy : h == "unhealthy" ? Help.unhealthy : Help.starting)
                    }
                }
                inspectTarget(
                    Text(c.isRunning ? c.image : "\(c.image) · \(c.status)")
                        .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle))
            }
            Spacer(minLength: 4)
            domainBadge
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

    /// The globe that opens the container at its domain name. A warning shows
    /// every note about the names of the container, also when it has a name.
    @ViewBuilder private var domainBadge: some View {
        if let rel = model.domainRoutes.primaryName(c.id), let url = model.domainURL(rel) {
            IconButton("globe", Help.domainLink(url.absoluteString)) { model.openDomain(rel) }
        }
        if let notes = model.domainRoutes.notes[c.id], !notes.isEmpty {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 11)).foregroundStyle(.orange)
                .hint(Help.domainNotes(notes, suffix: model.primaryDomainSuffix))
        }
    }

    /// The name and the image open the Inspect page. The health badge is
    /// not part of the target, so its hint does not hide the hint of the name.
    private func inspectTarget<V: View>(_ view: V) -> some View {
        view
            .contentShape(Rectangle())
            .onTapGesture { ui.inspectID = c.id }
            .hint(Help.inspect)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { ui.inspectID = c.id }
    }

    @ViewBuilder private var actions: some View {
        HStack(spacing: 0) {
            if c.isRunning {
                IconButton("text.alignleft", Help.logs) { model.openLogs(id: c.id, name: c.name) }
                IconButton("chevron.left.forwardslash.chevron.right", Help.shell) {
                    model.terminal(.containerShell, c.name)
                }
                IconButton("arrow.clockwise", Help.ctrRestart) { model.container(c.id, .restart) }
                IconButton("stop.fill", Help.ctrStop) { model.container(c.id, .stop) }
            } else {
                IconButton("text.alignleft", Help.logs) { model.openLogs(id: c.id, name: c.name) }
                IconButton("play.fill", Help.ctrStart) { model.container(c.id, .start) }
                IconButton("trash", Help.ctrRemove) { model.run(.containerRemove, c.name) }
            }
            Menu {
                Button("Inspect…") { ui.inspectID = c.id }
                Divider()
                Button("Logs in Terminal") { model.terminal(.containerLogs, c.name) }
                if c.state == "running" {
                    Button("Debug shell") { model.debugShell(c) }
                        .disabled(model.isDebug)
                        .hint(model.isDebug ? Help.debugShellDebug : Help.debugShell)
                }
                Divider()
                Button("Copy name") { Pasteboard.copy(c.name) }
                Button("Copy ID") { Pasteboard.copy(String(c.id.prefix(12))) }
                Button("Copy image") { Pasteboard.copy(c.image) }
                Button("Copy exec command") { Pasteboard.copy("docker exec -it \(c.name) sh") }
                if !c.ports.isEmpty {
                    Divider()
                    ForEach(c.ports, id: \.self) { p in Button("Open localhost:\(p)") { model.open(port: p) } }
                }
                if let names = model.domainRoutes.names[c.id], !names.isEmpty {
                    Divider()
                    ForEach(names, id: \.self) { rel in
                        Button("Open \(DomainLink.host(relative: rel, suffix: model.primaryDomainSuffix))") {
                            model.openDomain(rel)
                        }
                        .disabled(model.domainURL(rel) == nil)
                    }
                    if let url = names.first.flatMap({ model.domainURL($0) }) {
                        Button("Copy Address") { Pasteboard.copy(url.absoluteString) }
                    }
                }
                if c.isRunning {
                    Divider()
                    Button("Remove…") { model.run(.containerRemove, c.name) }
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
        Text(stat.map { ByteFormat.bytes($0.memBytes) } ?? "–")
            .frame(width: 54, alignment: .trailing)
            .hint(Help.ctrMem)
    }
}
