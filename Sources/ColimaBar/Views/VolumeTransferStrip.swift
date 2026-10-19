import SwiftUI

/// The strip at the top of the Volumes tab while a backup or restore runs:
/// what it does, how far it is, and **Cancel**.
struct VolumeTransferStrip: View {
    let model: ColimaModel
    let transfer: VolumeTransfer

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                // The progress bar carries this text as its label, so the text is not read twice.
                Text(transfer.text)
                    .font(.caption).lineLimit(1).truncationMode(.middle)
                    .accessibilityHidden(true)
                Spacer(minLength: 4)
                Button("Cancel") { model.cancelVolumeTransfer() }
                    .controlSize(.small)
                    .disabled(transfer.isCancelling)
                    .hint(Help.transferCancel)
            }
            Group {
                if let fraction = transfer.fraction {
                    ProgressView(value: fraction).controlSize(.small)
                } else {
                    ProgressView().progressViewStyle(.linear).controlSize(.small)
                }
            }
            .accessibilityLabel(transfer.text)
        }
        .padding(8)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
    }
}
