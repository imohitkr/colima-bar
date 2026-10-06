import SwiftUI

struct VolumesTab: View {
    let model: ColimaModel
    let search: String

    var body: some View {
        let q = search.lowercased()
        let list = model.volumes.filter {
            q.isEmpty || $0.name.lowercased().contains(q) || ($0.project?.lowercased().contains(q) ?? false)
        }
        let unused = model.volumes.filter { $0.links == 0 }
        // Lazy: a long list builds only the rows on screen.
        LazyVStack(alignment: .leading, spacing: 6) {
            SectionHeader(title: "\(model.volumes.count) volumes · \(unused.count) unused") {
                Button("Remove unused") { model.run(.prune, "volumes") }.buttonStyle(.borderless).font(.caption)
                    .hint(Help.removeUnusedVolumes)
            }
            if list.isEmpty { EmptyStateText(text: model.volumes.isEmpty ? "No volumes" : "No matches") }
            ForEach(list) { v in
                HStack(spacing: 8) {
                    Image(systemName: "externaldrive").foregroundStyle(.secondary).frame(width: 16)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(v.isAnonymous ? String(v.name.prefix(12)) + "…" : v.name)
                            .font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
                        Text(
                            [
                                v.project.map { "compose: \($0)" }, v.isAnonymous ? "anonymous" : nil,
                                v.links > 0 ? "used by \(v.links)" : "unused",
                            ].compactMap { $0 }.joined(separator: " · ")
                        )
                        .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .hint(
                        v.isAnonymous
                            ? Help.anonymous
                            : v.links == 0 ? Help.unusedVolume : "Volume \(v.name), used by \(v.links) container(s).")
                    Spacer(minLength: 4)
                    Text(ByteFormat.bytes(v.size)).font(.system(size: 11).monospacedDigit())
                        .frame(width: 60, alignment: .trailing)
                    Menu {
                        Button("Copy name") { Pasteboard.copy(v.name) }
                        Divider()
                        Button("Remove…") { model.run(.volumeRemove, v.name) }.disabled(v.links > 0)
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 22)
                }
                .padding(.vertical, 4).padding(.horizontal, 6)
                .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 6))
                .opacity(v.links > 0 ? 1 : 0.75)
            }
        }
    }
}
