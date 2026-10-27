import SwiftUI

/// One finding on the scan page: the ID of the vulnerability, the package
/// with its installed and fixed version, and the title.
struct ImageScanRow: View {
    let finding: ImageScanFinding

    /// The most width of the versions. The ID and the package get the rest.
    private static let versionsWidth: CGFloat = 130

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(ScanBadge.color(finding.severity)).frame(width: 7, height: 7)
                .hint(Help.scanSeverity(finding.severity.title))
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(finding.vulnID).font(.system(size: 12, weight: .medium)).lineLimit(1)
                        .layoutPriority(1)
                    Text(finding.package).font(.system(size: 11)).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 4)
                    versions
                }
                if !finding.title.isEmpty {
                    Text(finding.title).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                        .hint(finding.title)
                }
            }
            Menu {
                Button("Copy ID") { Pasteboard.copy(finding.vulnID) }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 22)
            .hint(Help.scanRowMenu)
        }
        .padding(.vertical, 4).padding(.horizontal, 6)
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 6))
    }

    @ViewBuilder private var versions: some View {
        if let fixed = finding.fixed {
            // The first fixed version matters most, so the end of the list goes.
            Text("\(finding.installed) → \(fixed)").font(.system(size: 10).monospacedDigit())
                .lineLimit(1).truncationMode(.tail).frame(maxWidth: Self.versionsWidth, alignment: .trailing)
                .hint(Help.scanFixed)
        } else {
            Text("\(finding.installed) · no fix").font(.system(size: 10).monospacedDigit())
                .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                .frame(maxWidth: Self.versionsWidth, alignment: .trailing).hint(Help.scanNoFix)
        }
    }
}
