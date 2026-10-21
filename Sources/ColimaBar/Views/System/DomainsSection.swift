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
        Toggle(isOn: Binding(get: { model.httpsEnabled }, set: { model.setHTTPS($0) })) {
            Label("Use HTTPS with a local certificate authority", systemImage: "lock")
        }
        .hint(Help.domainsHTTPS)
        .disabled(
            !model.domainsEnabled || model.isDebug || model.domainStatus.https.phase == .settingUp
                || model.domainStatus.https.phase == .removing
        )
        .padding(.leading, 22)
        if let caption = model.domainStatus.https.caption {
            Text(caption)
                .font(.caption2)
                .foregroundStyle(
                    model.domainStatus.https.phase == .failed || model.domainStatus.https.phase == .untrusted
                        ? Color.orange : .secondary
                )
                .padding(.leading, 44)
        }
        if model.domainStatus.https.phase == .untrusted {
            Button("Trust Again…") { model.trustCAAgain() }
                .hint(Help.domainsTrustAgain)
                .padding(.leading, 44)
        }
        if model.caExists {
            Button("Show Certificate") { model.showCACertificate() }
                .hint(Help.domainsShowCA)
                .disabled(model.isDebug)
                .padding(.leading, 44)
        }
    }
}
