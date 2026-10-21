import SwiftUI

/// The strip under the header while a VM type change runs: what it does, how
/// far it is, and **Cancel**. It shows on every page, so the change stays
/// visible when you leave the System tab.
struct VMRecreateStrip: View {
    let model: ColimaModel
    let progress: VMRecreateProgress

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                // The progress bar carries this text as its label, so the text is not read twice.
                Text(progress.text)
                    .font(.caption).lineLimit(1).truncationMode(.middle)
                    .accessibilityHidden(true)
                Spacer(minLength: 4)
                Button("Cancel") { model.cancelRecreate() }
                    .controlSize(.small)
                    .disabled(!progress.canCancel)
                    .hint(progress.canCancel || progress.isCancelling ? Help.recreateCancel : Help.recreateNoCancel)
            }
            Group {
                if let fraction = progress.fraction {
                    ProgressView(value: fraction).controlSize(.small)
                } else {
                    ProgressView().progressViewStyle(.linear).controlSize(.small)
                }
            }
            .accessibilityLabel(progress.text)
        }
        .padding(8)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
        .padding(.horizontal, 12).padding(.vertical, 6)
    }
}
