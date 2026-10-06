import SwiftUI

struct ContainersTab: View {
    let model: ColimaModel
    @Bindable var ui: ViewState

    // This body must not read stats or history: they change every second.
    // Only StatCells reads them, so a tick redraws just those numbers.
    var body: some View {
        let groups = grouped
        // Lazy: opening the dashboard builds only the rows on screen.
        LazyVStack(alignment: .leading, spacing: 6) {
            if groups.isEmpty {
                Empty(text: model.containers.isEmpty ? "No containers" : "No matches")
            }
            ForEach(groups, id: \.key) { g in
                let isCollapsed = Binding(
                    get: { ui.collapsed.contains(g.key) },
                    set: { if $0 { ui.collapsed.insert(g.key) } else { ui.collapsed.remove(g.key) } })
                SectionHeader(
                    title: g.title, collapsed: isCollapsed, hint: g.project == nil ? Help.standalone : Help.projectGroup
                ) {
                    if let project = g.project {
                        IconButton("play.fill", "Start all in \(project)") { model.project(project, "start") }
                        IconButton("arrow.clockwise", "Restart all in \(project)") { model.project(project, "restart") }
                        IconButton("stop.fill", "Stop all in \(project)") { model.project(project, "stop") }
                    } else if g.key == "~standalone", model.running.count > 1 {
                        Button("Stop all") { model.ctl("stop-all") }.buttonStyle(.borderless).font(.caption)
                            .hint(Help.stopAll)
                    }
                }
                if !isCollapsed.wrappedValue {
                    ForEach(g.items) { c in
                        ContainerRow(model: model, c: c)
                    }
                }
            }
            // Below the list: a new alert must not push the rows you're
            // reading down.
            if !model.alerts.isEmpty || !model.notificationsAllowed {
                AlertsStrip(model: model).padding(.top, 6)
            }
        }
    }

    private struct Group {
        let key: String
        let title: String
        let project: String?
        let items: [Container]
    }

    /// Compose projects first (alphabetical), then standalone containers.
    /// Inside each group: running before stopped, then by name.
    private var grouped: [Group] {
        let q = ui.search.lowercased()
        let list = model.containers.filter { c in
            (!ui.runningOnly || c.isRunning)
                && (q.isEmpty || c.name.lowercased().contains(q) || c.image.lowercased().contains(q)
                    || (c.project?.lowercased().contains(q) ?? false))
        }
        let order: (Container, Container) -> Bool = { a, b in
            a.isRunning != b.isRunning ? a.isRunning : a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
        var out: [Group] = []
        let byProject = Dictionary(grouping: list.filter { $0.project != nil }, by: { $0.project! })
        for p in byProject.keys.sorted() {
            let items = byProject[p]!.sorted(by: order)
            let up = items.filter(\.isRunning).count
            out.append(Group(key: "p:\(p)", title: "\(p)  ·  \(up)/\(items.count) running", project: p, items: items))
        }
        let solo = list.filter { $0.project == nil }.sorted(by: order)
        if !solo.isEmpty {
            let up = solo.filter(\.isRunning).count
            out.append(
                Group(
                    key: "~standalone", title: "Standalone  ·  \(up)/\(solo.count) running",
                    project: nil, items: solo))
        }
        return out
    }
}
