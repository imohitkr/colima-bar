import SwiftUI

/// One folder of the mount list: its path, the Writable checkbox and the
/// remove button.
struct VMMountRow: View {
    @Binding var mount: VMMount
    let enabled: Bool
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "folder").foregroundStyle(.secondary)
            Text(mount.location)
                .font(.system(size: 11, design: .monospaced))
                .lineLimit(1).truncationMode(.middle)
                .help(mount.location)
            Spacer(minLength: 4)
            Toggle("Writable", isOn: $mount.writable)
                .toggleStyle(.checkbox).font(.caption)
                .accessibilityLabel("Writable: \(mount.location)")
                .hint(Help.mountWritable)
            Button(action: remove) {
                Image(systemName: "minus.circle").foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Remove \(mount.location)")
            .hint(Help.mountRemove)
        }
        .disabled(!enabled)
    }
}
