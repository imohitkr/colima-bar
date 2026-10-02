import Charts
import ServiceManagement
import SwiftUI

enum Tab: String, CaseIterable, Identifiable {
    case containers = "Containers", images = "Images", volumes = "Volumes", system = "System"
    var id: String { rawValue }
}

/// UI state that must survive the popover closing and reopening.
@MainActor @Observable
final class ViewState {
    var tab: Tab = .containers
    var search = ""
    var runningOnly = false
    var collapsed: Set<String> = []
    let system = SystemForm()
}

struct DashboardView: View {
    @Bindable var model: ColimaModel
    @Bindable var ui: ViewState
    var inWindow = false
    var openWindow: () -> Void = {}

    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HeaderView(model: model)
            Divider()
            if model.state == .running {
                LiveTiles(model: model).padding(.horizontal, 12).padding(.vertical, 10)
                Picker("", selection: $ui.tab) {
                    ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden()
                .padding(.horizontal, 12).padding(.bottom, 8)
                if ui.tab != .system { searchBar }
                Divider()
                ScrollView {
                    Group {
                        switch ui.tab {
                        case .containers: ContainersTab(model: model, ui: ui)
                        case .images: ImagesTab(model: model, search: ui.search)
                        case .volumes: VolumesTab(model: model, search: ui.search)
                        case .system: SystemTab(model: model, form: ui.system)
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollIndicators(.automatic)
            } else {
                StoppedView(model: model)
            }
            Divider()
            FooterView(model: model, inWindow: inWindow, openWindow: openWindow)
        }
        // Fixed size in the popover: it never resizes while you're reading it.
        .frame(width: inWindow ? nil : 480, height: inWindow ? nil : 640)
        .frame(minWidth: inWindow ? 480 : nil, minHeight: inWindow ? 500 : nil)
        .transaction { $0.animation = nil }
        .background {
            Button("") { Task { await model.refreshAll() } }.keyboardShortcut("r").hidden()
            Button("") { searchFocused = true }.keyboardShortcut("f").hidden()
        }
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Filter \(ui.tab.rawValue.lowercased())", text: $ui.search)
                    .textFieldStyle(.plain).focused($searchFocused)
                if !ui.search.isEmpty {
                    Button { ui.search = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 7).padding(.vertical, 4)
            .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
            if ui.tab == .containers {
                Toggle("Running only", isOn: $ui.runningOnly).toggleStyle(.checkbox).font(.caption)
            }
        }
        .padding(.horizontal, 12).padding(.bottom, 8)
    }
}

// MARK: - Header / footer

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
                    if let busy = model.busy {
                        ProgressView().controlSize(.mini)
                        Text(busy + "…").font(.caption).foregroundStyle(.orange)
                    } else {
                        Text(stateText).font(.caption).foregroundStyle(color)
                    }
                }
                Text(subtitle).font(.caption).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
            }
            Spacer()
            if model.state == .running {
                IconButton("arrow.clockwise", "Restart Colima") { model.ctl("restart") }
                IconButton("stop.fill", "Stop Colima") { model.ctl("stop") }
            } else if model.state == .stopped {
                IconButton("play.fill", "Start Colima") { model.ctl("start") }
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
        case .unknown: return .secondary
        }
    }

    private var stateText: String {
        switch model.state {
        case .running: return "Running"
        case .stopped: return "Stopped"
        case .unknown: return "Checking…"
        }
    }

    private var subtitle: String {
        guard model.state == .running else { return "default profile" }
        let v = model.vm
        var parts = ["\(v.cpus) CPU", "\(v.memGB) GB", "\(v.diskGB) GB disk", v.arch]
        if !v.mountType.isEmpty { parts.append(v.mountType) }
        if model.rosetta { parts.append("rosetta") }
        if model.k8s { parts.append("k3s") }
        return parts.joined(separator: " · ")
    }
}

struct FooterView: View {
    let model: ColimaModel
    let inWindow: Bool
    let openWindow: () -> Void

    var body: some View {
        HStack(spacing: 2) {
            IconButton("terminal", "SSH into the VM") { model.terminal("ssh") }
            IconButton("doc.on.clipboard", "Copy DOCKER_HOST export") { model.ctl("copy-env") }
            IconButton("doc.text", "Open colima.yaml") { model.ctl("config") }
            IconButton("list.bullet.rectangle", "Open Colima log") { model.ctl("logs") }
            Spacer()
            if !inWindow {
                IconButton("macwindow", "Open in a window") { openWindow() }
            }
            IconButton("arrow.clockwise.circle", "Refresh (⌘R)") { Task { await model.refreshAll() } }
            IconButton("power", "Quit ColimaBar") { NSApp.terminate(nil) }
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
    }
}

struct StoppedView: View {
    let model: ColimaModel

    var body: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "shippingbox").font(.system(size: 44)).foregroundStyle(.secondary)
            Text(model.state == .unknown ? "Checking Colima…" : "Colima is stopped").font(.title3)
            if model.state == .stopped {
                Button { model.ctl("start") } label: {
                    Label("Start Colima", systemImage: "play.fill").frame(width: 160)
                }
                .controlSize(.large).buttonStyle(.borderedProminent)
                .disabled(model.busy != nil)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Live tiles

struct LiveTiles: View {
    let model: ColimaModel

    var body: some View {
        HStack(spacing: 10) {
            Tile(title: "CPU", value: cpuText, detail: "of \(model.vm.cpus) cores",
                 history: model.cpuHistory, tint: .blue)
            Tile(title: "Memory", value: memText, detail: "of \(model.vm.memGB) GB",
                 history: model.memHistory, tint: .purple)
            VStack(alignment: .leading, spacing: 4) {
                Text("Containers").font(.caption).foregroundStyle(.secondary)
                Text("\(model.running.count)").font(.title2.weight(.semibold)).monospacedDigit()
                Text("\(model.stopped.count) stopped").font(.caption2).foregroundStyle(.secondary)
                if unhealthy > 0 {
                    Text("\(unhealthy) unhealthy").font(.caption2).foregroundStyle(.red)
                }
            }
            .frame(width: 92, height: 72, alignment: .topLeading)
            .padding(8)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private var unhealthy: Int { model.running.filter { $0.health == "unhealthy" }.count }
    private var totalMem: Double { model.stats.values.reduce(0) { $0 + $1.memBytes } }
    private var cpuText: String {
        model.cpuHistory.last.map { String(format: "%.1f%%", $0) } ?? "–"
    }
    private var memText: String { model.stats.isEmpty ? "–" : Fmt.bytes(totalMem) }
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
            Chart(Array(history.enumerated()), id: \.offset) { p in
                AreaMark(x: .value("t", p.offset), y: .value("v", p.element))
                    .foregroundStyle(tint.opacity(0.18))
                LineMark(x: .value("t", p.offset), y: .value("v", p.element))
                    .foregroundStyle(tint).lineStyle(StrokeStyle(lineWidth: 1.2))
            }
            .chartXScale(domain: 0...59)
            .chartYScale(domain: 0...max(100, history.max() ?? 0))
            .chartXAxis(.hidden).chartYAxis(.hidden)
            .frame(height: 30)
        }
        .frame(height: 72)
        .padding(8)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Shared bits

struct IconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void

    init(_ symbol: String, _ help: String, action: @escaping () -> Void) {
        self.symbol = symbol
        self.help = help
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).frame(width: 22, height: 20).contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(help)
    }
}

struct SectionHeader<Trailing: View>: View {
    let title: String
    var collapsed: Binding<Bool>? = nil
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 4) {
            if let collapsed {
                Button { collapsed.wrappedValue.toggle() } label: {
                    Image(systemName: collapsed.wrappedValue ? "chevron.right" : "chevron.down")
                        .font(.caption2.weight(.bold)).frame(width: 12)
                    Text(title).font(.caption.weight(.semibold))
                }
                .buttonStyle(.plain)
            } else {
                Text(title).font(.caption.weight(.semibold))
            }
            Spacer()
            trailing
        }
        .foregroundStyle(.secondary)
        .padding(.top, 4)
    }
}

extension SectionHeader where Trailing == EmptyView {
    init(title: String) { self.init(title: title, trailing: { EmptyView() }) }
}

func copy(_ s: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(s, forType: .string)
}
