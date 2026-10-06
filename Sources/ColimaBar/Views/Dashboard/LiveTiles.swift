import SwiftUI

struct LiveTiles: View {
    let model: ColimaModel

    var body: some View {
        HStack(spacing: 10) {
            Tile(
                title: "CPU", value: cpuText, detail: "of \(model.vm.cpus) cores",
                history: model.cpuHistory, tint: .blue
            )
            .hint(Help.cpuTile)
            Tile(
                title: "Memory", value: memText, detail: "of \(model.vm.memGB) GB",
                history: model.memHistory, tint: .purple
            )
            .hint(Help.memTile)
            ContainersTile(model: model)
        }
    }

    private var totalMem: Double { model.stats.values.reduce(0) { $0 + $1.memBytes } }
    private var cpuText: String {
        model.cpuHistory.last.map { String(format: "%.1f%%", $0) } ?? "–"
    }
    private var memText: String { model.stats.isEmpty ? "–" : ByteFormat.bytes(totalMem) }
}

/// Container counts. A separate view, so the 1 s stats tick that redraws
/// the CPU and memory tiles doesn't redraw this one.
struct ContainersTile: View {
    let model: ColimaModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Containers").font(.caption).foregroundStyle(.secondary)
            Text("\(model.running.count)").font(.title2.weight(.semibold)).monospacedDigit()
            // One line either way, so the tile never grows past its height.
            if unhealthy > 0 {
                Text("\(unhealthy) unhealthy").font(.caption2).foregroundStyle(.red).lineLimit(1)
            } else {
                Text("\(model.stopped.count) stopped").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .frame(width: 92, height: 72, alignment: .topLeading)
        .padding(8)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
        .hint(Help.ctrTile)
    }

    private var unhealthy: Int { model.running.filter { $0.health == "unhealthy" }.count }
}

struct Tile: View {
    let title: String
    let value: String
    let detail: String
    let history: [Double]
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(detail).font(.caption2).foregroundStyle(.tertiary)
            }
            Text(value).font(.title3.weight(.semibold)).monospacedDigit()
            ZStack {
                Sparkline(values: history, area: true).fill(tint.opacity(0.18))
                Sparkline(values: history).stroke(tint, style: StrokeStyle(lineWidth: 1.2))
            }
            .frame(height: 30)
        }
        .frame(height: 72)
        .padding(8)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }
}
