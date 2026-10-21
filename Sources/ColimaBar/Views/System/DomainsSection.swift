import SwiftUI

/// The switch for container domains and a line about the proxy.
struct DomainsSection: View {
    @Bindable var model: ColimaModel

    var body: some View {
        Divider()
        SectionHeader(title: "Domains", hint: Help.domainLabels) { EmptyView() }
        Toggle(isOn: $model.domainsEnabled) {
            Label("Open containers at .localhost names", systemImage: "globe")
        }
        .hint(Help.domains)
        .disabled(model.isDebug)
        if let caption = model.domainStatus.caption(routeCount: model.domainRoutes.count) {
            Text(caption)
                .font(.caption2)
                .foregroundStyle(model.domainStatus.phase == .failed ? Color.orange : .secondary)
                .padding(.leading, 22)
        }
        ForEach(model.domainRestartHints) { hint in
            Text(hint.text)
                .font(.caption2)
                .foregroundStyle(Color.orange)
                .padding(.leading, 22)
        }
    }
}
