import SwiftUI

/// One `KEY value` row of the Inspect page, for the environment and for the
/// labels. A secret value shows as dots until the user clicks the eye.
struct InspectEnvRow: View {
    let key: String
    let value: String
    let isSecret: Bool
    var keyColor: Color = .secondary
    let isRevealed: Bool
    let toggle: () -> Void

    private var hidden: Bool { isSecret && !isRevealed }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(key).font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundStyle(keyColor)
                .lineLimit(1).truncationMode(.middle)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(hidden ? EnvMask.mask : (value.isEmpty ? "(empty)" : value))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(value.isEmpty && !hidden ? .tertiary : .primary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                if isSecret {
                    IconButton(
                        isRevealed ? "eye.slash" : "eye", isRevealed ? Help.hideValue : Help.revealValue, action: toggle
                    )
                    .accessibilityLabel(isRevealed ? "Hide \(key)" : "Show \(key)")
                }
                // The copy button copies the raw value, also while it is hidden.
                IconButton("doc.on.doc", Help.copyValue) { Pasteboard.copy(value) }
                    .accessibilityLabel("Copy \(key)")
            }
        }
        .padding(.vertical, 1)
    }
}
