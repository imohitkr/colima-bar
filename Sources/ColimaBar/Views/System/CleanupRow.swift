import SwiftUI

/// One row of the Cleanup page: an icon, the title and detail, the size and
/// the button that removes the item. `onRemove` runs the removal.
struct CleanupRow: View {
    let item: CleanupItem
    let isDebug: Bool
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon).foregroundStyle(.secondary).frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
                if !item.detail.isEmpty {
                    Text(item.detail).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            Spacer(minLength: 4)
            if item.inUse && item.kind == .image {
                Text("in use").font(.system(size: 9, weight: .medium))
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .background(.green.opacity(0.15), in: Capsule()).foregroundStyle(.green)
                    .hint(Help.inUse)
            }
            Text(ByteFormat.bytes(item.size)).font(.system(size: 11).monospacedDigit())
                .frame(width: 60, alignment: .trailing)
            if item.removal != nil {
                Button(item.kind == .log ? "Empty…" : "Remove…", action: onRemove)
                    .controlSize(.mini).disabled(isDebug)
                    .hint(isDebug ? Help.cleanupDebug : removeHint)
            } else if item.kind == .image {
                Color.clear.frame(width: 56, height: 1)
                    .hint(item.inUse ? Help.cleanupImageInUse : Help.cleanupImageTags)
            }
        }
        .padding(.vertical, 4).padding(.horizontal, 6)
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 6))
    }

    private var icon: String {
        switch item.kind {
        case .image: item.title == "<none>" ? "square.dashed" : "square.stack.3d.up"
        case .volume: "externaldrive"
        case .container: "shippingbox"
        case .buildCache: "line.3.horizontal"
        case .log: "doc.text"
        }
    }

    private var removeHint: String {
        switch item.kind {
        case .image: Help.cleanupImageRemove
        case .volume: Help.cleanupVolumeRemove
        case .container: Help.cleanupContainerRemove
        case .log: Help.cleanupLogEmpty
        case .buildCache: Help.cleanupCache
        }
    }
}
