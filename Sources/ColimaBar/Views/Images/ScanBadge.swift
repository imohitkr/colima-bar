import SwiftUI

/// The capsule on an image row after a scan: the highest severity and its
/// count ("3 critical"), or "clean". A click opens the page of the scan.
struct ScanBadge: View {
    let report: ImageScanReport
    let open: () -> Void

    var body: some View {
        let color = Self.color(report.highest)
        Button(action: open) {
            Text(report.badgeText)
                .font(.system(size: 9, weight: .medium))
                .fixedSize()
                .padding(.horizontal, 4).padding(.vertical, 1)
                .background(color.opacity(0.15), in: Capsule())
                .foregroundStyle(color)
        }
        .buttonStyle(.plain)
        .hint(Help.scanBadge(report.badgeText))
    }

    /// The color of a severity. Nil is a clean image.
    static func color(_ severity: ImageScanSeverity?) -> Color {
        switch severity {
        case .critical: .red
        case .high: .orange
        case .medium: .yellow
        case .low: .blue
        case .unknown: .gray
        case nil: .green
        }
    }
}
