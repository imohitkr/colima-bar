import SwiftUI

/// The row "kubectl: CONTEXT · NAMESPACE" under the Kubernetes toggle. It
/// shows only when kubectl exists and the setting is on. A pick runs
/// `kubectl config` and changes nothing else in the kubeconfig.
struct KubeContextRow: View {
    var model: ColimaModel

    var body: some View {
        HStack(spacing: 6) {
            // The namespace items below belong to the context that this row shows.
            let context = model.kubeConfig?.current
            if model.kubeConfig == nil {
                Text(ContextMenuRules.kubeLabel(nil, failed: model.kubeReadFailed)).font(.caption2).foregroundStyle(
                    .secondary)
            } else {
                Menu(ContextMenuRules.kubeLabel(model.kubeConfig, failed: false)) {
                    Menu("Context") {
                        ForEach(model.kubeContextEntries) { entry in
                            Button {
                                Task { await model.switchKubeContext(to: entry.name) }
                            } label: {
                                if entry.isCurrent {
                                    Label(entry.title, systemImage: "checkmark")
                                } else {
                                    Text(entry.title)
                                }
                            }
                            .disabled(model.isDebug)
                        }
                    }
                    if let context {
                        Menu("Namespace") {
                            ForEach(model.kubeNamespaceEntries) { entry in
                                Button {
                                    Task { await model.setKubeNamespace(entry.name, context: context) }
                                } label: {
                                    if entry.isCurrent {
                                        Label(entry.title, systemImage: "checkmark")
                                    } else {
                                        Text(entry.title)
                                    }
                                }
                                .disabled(model.isDebug)
                            }
                            Divider()
                            Button("Other…") { KubeNamespaceAlert.ask(model: model, context: context) }
                                .disabled(model.isDebug)
                        }
                    }
                }
                .menuStyle(.borderlessButton).fixedSize().controlSize(.small)
                .hint(model.isDebug ? Help.contextDebug : Help.kubeContext)
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, 22)
    }
}
