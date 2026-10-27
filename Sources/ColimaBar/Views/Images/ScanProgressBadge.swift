import SwiftUI

/// The capsule on an image row while a scan of that image runs, and after a
/// scan of it failed. A click opens the page of the scan, which shows the
/// progress and the Cancel button, or the reason of the failure.
struct ScanProgressBadge: View {
    let state: ImageScanState
    let open: () -> Void

    var body: some View {
        if let text = Self.text(for: state) {
            let color: Color = state.isRunning ? .secondary : .orange
            Button(action: open) {
                Text(text)
                    .font(.system(size: 9, weight: .medium))
                    .fixedSize()
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .background(color.opacity(0.15), in: Capsule())
                    .foregroundStyle(color)
            }
            .buttonStyle(.plain)
            .hint(state.isRunning ? Help.scanRunningBadge : Help.scanFailedBadge)
        }
    }

    /// "scanning…" while the scan runs, "scan failed" after a failure, and
    /// nil after a scan that gave a report or that the user cancelled.
    nonisolated static func text(for state: ImageScanState) -> String? {
        switch state.phase {
        case .exporting, .scanning: "scanning…"
        case .failed(let error): error == .cancelled ? nil : "scan failed"
        case .done: nil
        }
    }
}
