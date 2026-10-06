import SwiftUI

/// Recent alerts (crash, OOM, unhealthy, failed actions), so nothing is
/// missed even with notifications off. Buttons work only while the container
/// still exists.
struct AlertsStrip: View {
    @Bindable var model: ColimaModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !model.notificationsAllowed {
                HStack(spacing: 6) {
                    Image(systemName: "bell.slash").foregroundStyle(.orange)
                    Text("Notifications are off for ColimaBar, so alerts only show here.")
                        .font(.caption)
                    Spacer()
                    Button("Enable…") { Notifier.openSettings() }.controlSize(.mini)
                        .hint(Help.enableNotifications)
                }
            }
            if !model.alerts.isEmpty {
                SectionHeader(title: "Recent alerts") {
                    Button("Clear") { model.clearAlerts() }.buttonStyle(.borderless).font(.caption)
                        .hint("Dismiss these alerts.")
                }
                ForEach(model.alerts.prefix(5)) { a in
                    let ctr = a.containerID.flatMap { model.container(withID: $0) }
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.caption)
                        VStack(alignment: .leading, spacing: 0) {
                            Text("\(a.title): \(a.body)").font(.system(size: 11)).lineLimit(1)
                            Text(
                                a.date.formatted(date: .omitted, time: .shortened)
                                    + (a.containerID != nil && ctr == nil ? " · container removed" : "")
                            )
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if let ctr {
                            IconButton("text.alignleft", Help.logs) { model.openLogs(id: ctr.id, name: ctr.name) }
                            IconButton("arrow.clockwise", Help.ctrRestart) { model.container(ctr.id, .restart) }
                        }
                    }
                    .padding(.vertical, 3).padding(.horizontal, 6)
                    .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                }
            }
        }
        .padding(.bottom, 4)
    }
}
