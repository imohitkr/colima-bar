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
                .hint(Help.tabs)
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
            HintBar()
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
            .hint(Help.search)
            if ui.tab == .containers {
                Toggle("Running only", isOn: $ui.runningOnly).toggleStyle(.checkbox).font(.caption)
                    .hint(Help.runningOnly)
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
                IconButton("arrow.clockwise", Help.restart) { model.ctl("restart") }
                IconButton("stop.fill", Help.stopVM) { model.ctl("stop") }
            } else if model.state == .stopped {
                IconButton("play.fill", Help.startVM) { model.ctl("start") }
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
            IconButton("terminal", Help.ssh) { model.terminal("ssh") }
            IconButton("doc.on.clipboard", Help.copyEnv) {
                model.ctl("copy-env")
                Hint.shared.text = "Copied the DOCKER_HOST export to the clipboard."
            }
            IconButton("doc.text", Help.config) { model.ctl("config") }
            IconButton("list.bullet.rectangle", Help.log) { model.ctl("logs") }
            Spacer()
            if !inWindow {
                IconButton("macwindow", Help.window) { openWindow() }
            }
            IconButton("arrow.clockwise.circle", Help.refresh) { Task { await model.refreshAll() } }
            IconButton("power", Help.quit) { NSApp.terminate(nil) }
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
            Text(title).font(.title3)
            if model.state == .notInstalled {
                Text("Install it with Homebrew, then reopen this menu:").foregroundStyle(.secondary)
                Text("brew install colima docker").font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
            }
            if model.state == .stopped {
                if model.autoStart {
                    Text("It will start by itself when something uses docker.")
                        .font(.caption).foregroundStyle(.secondary)
                }
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

    private var title: String {
        switch model.state {
        case .unknown: return "Checking Colima…"
        case .notInstalled: return "Colima isn't installed"
        default: return "Colima (\(model.profile)) is stopped"
        }
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
                    Text("\(p.name == model.profile ? "✓ " : "")\(p.name)  ·  \(p.running ? "running" : "stopped")")
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

// MARK: - Live tiles

struct LiveTiles: View {
    let model: ColimaModel

    var body: some View {
        HStack(spacing: 10) {
            Tile(title: "CPU", value: cpuText, detail: "of \(model.vm.cpus) cores",
                 history: model.cpuHistory, tint: .blue)
                .hint(Help.cpuTile)
            Tile(title: "Memory", value: memText, detail: "of \(model.vm.memGB) GB",
                 history: model.memHistory, tint: .purple)
                .hint(Help.memTile)
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
            .hint(Help.ctrTile)
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
        .hint(help)
        .accessibilityLabel(String(help.split(separator: ".").first ?? Substring(help)))
    }
}

struct SectionHeader<Trailing: View>: View {
    let title: String
    var collapsed: Binding<Bool>? = nil
    var hint: String? = nil
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
            if let hint {
                Image(systemName: "info.circle").font(.caption2).foregroundStyle(.tertiary).hint(hint)
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
