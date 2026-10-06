import SwiftUI

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
                    ForEach(DashboardTab.allCases) { Text($0.rawValue).tag($0) }
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
        // The model fetches disk usage and routing only for the tabs that show them.
        .onChange(of: ui.tab, initial: true) { model.dashboardTab = ui.tab }
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
                    Button {
                        ui.search = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
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
