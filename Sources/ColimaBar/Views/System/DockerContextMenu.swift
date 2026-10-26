import SwiftUI

/// The row "docker context: NAME" of the System tab. A click on the name
/// opens the list of docker contexts. A pick switches the docker CLI only.
struct DockerContextMenu: View {
    var model: ColimaModel

    var body: some View {
        let ours = Routing.isOurs(model.dockerContextCurrent)
        HStack(spacing: 6) {
            Image(systemName: ours ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(ours ? Color.green : .secondary)
            Text("docker context:").font(.caption)
            Menu(ContextMenuRules.currentLabel(model.dockerContextCurrent)) {
                ForEach(model.dockerContextEntries) { entry in
                    Button {
                        Task { await model.switchDockerContext(to: entry.name) }
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
            .menuStyle(.borderlessButton).fixedSize().controlSize(.small)
            .hint(model.isDebug ? Help.contextDebug : Help.dockerContextMenu)
        }
        .hint(Help.routeContext)
    }
}
