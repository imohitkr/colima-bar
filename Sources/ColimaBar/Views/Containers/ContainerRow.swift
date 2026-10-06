import SwiftUI

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
                Button("Logs in iTerm") { model.terminal(.containerLogs, c.name) }
                Divider()
                Button("Copy name") { Pasteboard.copy(c.name) }
                Button("Copy ID") { Pasteboard.copy(String(c.id.prefix(12))) }
                Button("Copy image") { Pasteboard.copy(c.image) }
                Button("Copy exec command") { Pasteboard.copy("docker exec -it \(c.name) sh") }
                if !c.ports.isEmpty {
                    Divider()
                    ForEach(c.ports, id: \.self) { p in Button("Open localhost:\(p)") { model.open(port: p) } }
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
