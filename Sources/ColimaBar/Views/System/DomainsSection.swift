import SwiftUI

/// The switch for container domains and a line about the proxy.
struct DomainsSection: View {
    @Bindable var model: ColimaModel
    @Bindable var form: SystemForm

    var body: some View {
        Divider()
        SectionHeader(title: "Domains", hint: Help.domainLabels) { EmptyView() }
        Toggle(isOn: $model.domainsEnabled) {
            Label("Open containers at .localhost names", systemImage: "globe")
        }
        .hint(Help.domains)
        .disabled(model.isDebug || model.domainStatus.dns.phase == .applying)
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
            (!model.domainsEnabled && !model.httpsEnabled) || model.isDebug
                || model.domainStatus.https.phase == .settingUp
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
        if model.domainStatus.https.phase == .off, model.domainStatus.https.offersCleanUp {
            Button("Delete Certificate…") { model.cleanUpLeftoverCA() }
                .hint(Help.domainsDeleteCA)
                .disabled(model.isDebug)
                .padding(.leading, 44)
        }
        if model.caExists {
            Button("Show Certificate") { model.showCACertificate() }
                .hint(Help.domainsShowCA)
                .disabled(model.isDebug)
                .padding(.leading, 44)
        }
        suffixRows
    }

    private var suffixOn: Bool { model.domainSuffix != nil || form.suffixEditing }

    @ViewBuilder private var suffixRows: some View {
        Toggle(
            isOn: Binding(
                get: { suffixOn },
                set: { on in
                    if on {
                        // A text that the user typed before a cancel stays.
                        if let current = model.domainSuffix {
                            form.suffixText = current
                        } else if form.suffixText.isEmpty {
                            form.suffixText = DomainSuffix.defaultValue
                        }
                        form.suffixEditing = true
                    } else {
                        form.suffixEditing = false
                        if model.domainSuffix != nil { Task { await model.removeSuffix() } }
                    }
                })
        ) {
            Label("Also use a custom suffix", systemImage: "network")
        }
        .hint(Help.domainSuffix)
        // Turning the suffix off works with the master switch off too.
        .disabled(
            model.isDebug || model.domainStatus.dns.phase == .applying
                || (!model.domainsEnabled && model.domainSuffix == nil)
        )
        .padding(.leading, 22)
        if suffixOn {
            let problem = DomainSuffix.problem(form.suffixText)
            let unchanged = DomainSuffix.normalized(form.suffixText) == model.domainSuffix
            HStack {
                TextField(DomainSuffix.defaultValue, text: $form.suffixText)
                    .textFieldStyle(.roundedBorder)
                    .disabled(model.isDebug || model.domainStatus.dns.phase == .applying)
                Button("Apply") {
                    let text = form.suffixText
                    Task { await model.applySuffix(text) }
                }
                .hint(Help.domainSuffixApply)
                .disabled(
                    problem != nil || unchanged || !model.domainsEnabled || model.isDebug
                        || model.domainStatus.dns.phase == .applying)
            }
            .padding(.leading, 44)
            if let problem, !unchanged {
                Text(problem).font(.caption2).foregroundStyle(Color.red).padding(.leading, 44)
            }
        }
        if let caption = model.domainSuffixCaption {
            Text(caption)
                .font(.caption2)
                .foregroundStyle(model.domainStatus.dns.phase == .failed ? Color.orange : .secondary)
                .padding(.leading, 44)
        }
        if model.domainStatus.dns.phase == .failed || model.domainStatus.dns.phase == .notUsedYet {
            Button("Repair…") { Task { await model.repairDNS() } }
                .hint(Help.domainSuffixRepair)
                .padding(.leading, 44)
        }
    }
}
