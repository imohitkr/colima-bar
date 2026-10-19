import SwiftUI

/// The notice for a broken port forward or a VM that cannot resolve host
/// names. It shows only for the selected profile, after a check found the
/// problem twice. Each row has the fix that fits, and one button checks
/// again.
struct NetworkNotice: View {
    let model: ColimaModel
    @Bindable var ui: ViewState

    private var ports: PortHealth.Report? {
        model.portHealth[model.profile].flatMap { $0.isBroken ? $0 : nil }
    }

    private var dns: DNSHealth.Report? {
        model.dnsHealth[model.profile].flatMap { $0.isBroken ? $0 : nil }
    }

    private var checking: Bool { model.isCheckingNetwork(model.profile) }

    private var locked: Bool { model.busy != nil || model.isDebug }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let ports { portsRow(ports) }
            if let dns { dnsRow(dns) }
            if let error = model.networkCheckErrors["ports|\(model.profile)"], !checking {
                Text(error).font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 6) {
                Button("Check again") { model.checkNetworkAgain() }
                    .controlSize(.mini).disabled(checking)
                    .hint(Help.networkCheckAgain)
                if checking {
                    ProgressView().controlSize(.mini)
                    Text("Checking…").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 6).padding(.horizontal, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
    }

    private func portsRow(_ report: PortHealth.Report) -> some View {
        let grpc = model.vmSettings?.portForwarder == "grpc"
        return row(PortHealth.noticeText(ports: report.broken), hint: Help.networkPorts) {
            restart
            if grpc {
                Button("Use ssh forwarder") { Task { await model.useSSHForwarder() } }
                    .controlSize(.mini).disabled(locked)
                    .hint(model.isDebug ? Help.doctorDebug : Help.doctorFix(.useSSHForwarder))
            }
        }
    }

    private func dnsRow(_ report: DNSHealth.Report) -> some View {
        var override = false
        if case .broken(let o) = report.verdict { override = o }
        return row(DNSHealth.noticeText(override: override), hint: Help.networkDNS) {
            if override {
                Button("Use the Mac's DNS") { Task { await model.useMacDNS() } }
                    .controlSize(.mini).disabled(locked)
                    .hint(model.isDebug ? Help.doctorDebug : Help.doctorFix(.useMacDNS))
            } else {
                restart
            }
            Button("Set DNS servers…") { ui.showVMConfig = true }
                .controlSize(.mini)
                .hint(Help.networkSetDNS)
        }
    }

    private var restart: some View {
        Button("Restart") { model.restartFromAlert(model.profile) }
            .controlSize(.mini).disabled(locked)
            .hint(model.isDebug ? Help.doctorDebug : Help.networkRestart)
    }

    private func row<Buttons: View>(
        _ text: String, hint: String, @ViewBuilder buttons: () -> Buttons
    ) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.caption)
            VStack(alignment: .leading, spacing: 4) {
                Text(text).font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) { buttons() }
            }
        }
        .hint(hint)
    }
}
