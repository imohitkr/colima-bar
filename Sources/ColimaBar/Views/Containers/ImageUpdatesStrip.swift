import SwiftUI

/// One line below the container list: how many images have a newer version,
/// with Pull All and Check Now. It shows only while the setting is on.
struct ImageUpdatesStrip: View {
    let model: ColimaModel

    var body: some View {
        let updates = model.imageUpdates.updateRefs.count
        let pulling = !model.imageUpdates.pulling.isEmpty
        HStack(spacing: 6) {
            Image(systemName: "arrow.down.circle").foregroundStyle(updates > 0 ? Color.blue : .secondary)
                .font(.caption)
            Text(label(updates))
                .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            if pulling || model.imageUpdates.checking { ProgressView().controlSize(.mini) }
            Spacer()
            if updates > 0 {
                Button("Pull All") { model.pullAllImageUpdates() }
                    .controlSize(.mini).disabled(pulling || !model.canPullImages)
                    .hint(model.isDebug ? Help.imageUpdateDebug : Help.pullAllImages)
            }
            Button("Check Now") { model.checkImagesNow() }
                .controlSize(.mini).disabled(!model.canCheckImagesNow)
                .hint(model.isDebug ? Help.imageUpdateDebug : Help.checkImagesNow)
        }
        .padding(.vertical, 3).padding(.horizontal, 6)
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 6))
        .hint(Help.imageUpdatesStrip)
    }

    private func label(_ updates: Int) -> String {
        switch updates {
        case 0: "No image updates"
        case 1: "1 image update"
        default: "\(updates) image updates"
        }
    }
}
