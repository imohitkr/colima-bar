import SwiftUI

/// The look of one `HeaderButtonStyle` button. A view of its own, because
/// the enabled state comes from the environment.
struct HeaderButtonLabel: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        configuration.label
            .font(.caption.weight(.medium))
            .lineLimit(1).fixedSize()
            .padding(.horizontal, 7).padding(.vertical, 2)
            .foregroundStyle(isEnabled ? Color.primary : Color.secondary)
            .background(.quaternary.opacity(fill), in: Capsule())
            .opacity(isEnabled ? 1 : 0.5)
            .contentShape(Capsule())
    }

    private var fill: Double {
        guard isEnabled else { return 0.3 }
        return configuration.isPressed ? 1 : 0.5
    }
}
