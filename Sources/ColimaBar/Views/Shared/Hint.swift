import SwiftUI

/// What the pointer is over. Shown in the dashboard's hint bar the moment you
/// hover, and also attached as a native tooltip.
@MainActor @Observable
final class Hint {
    static let shared = Hint()
    var text: String?
}

extension View {
    /// Explains this control: instantly in the hint bar, and as a tooltip.
    func hint(_ text: String) -> some View {
        self
            .help(text)
            .onHover { inside in
                let h = Hint.shared
                if inside {
                    h.text = text
                } else if h.text == text {
                    h.text = nil
                }
            }
    }
}

/// Fixed-height strip above the footer, so hovering never shifts the layout.
struct HintBar: View {
    let hint = Hint.shared

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: hint.text == nil ? "cursorarrow.rays" : "info.circle.fill")
                .foregroundStyle(hint.text == nil ? AnyShapeStyle(.tertiary) : AnyShapeStyle(Color.accentColor))
            Text(hint.text ?? "Hover over anything to see what it does.")
                .foregroundStyle(hint.text == nil ? .tertiary : .secondary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .font(.system(size: 11))
        .padding(.horizontal, 12).padding(.vertical, 6)
        .frame(height: 58, alignment: .topLeading)
        .background(.quaternary.opacity(0.25))
    }
}
