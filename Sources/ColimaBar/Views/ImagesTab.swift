import SwiftUI

struct ImagesTab: View {
    let model: ColimaModel
    let search: String

    var body: some View {
        let q = search.lowercased()
        let list = model.images.filter {
            q.isEmpty || $0.repo.lowercased().contains(q) || $0.tag.lowercased().contains(q)
        }
        let unused = model.images.filter { $0.containers == 0 }
        // Lazy: a long list builds only the rows on screen.
        LazyVStack(alignment: .leading, spacing: 6) {
            SectionHeader(title: "\(model.images.count) images · \(unused.count) unused") {
                Button("Remove dangling") { model.run(.prune, "dangling") }.buttonStyle(.borderless).font(.caption)
                    .hint(Help.removeDangling)
                Button("Remove unused") { model.run(.prune, "images") }.buttonStyle(.borderless).font(.caption)
                    .hint(Help.removeUnusedImages)
            }
            if list.isEmpty { EmptyStateText(text: model.images.isEmpty ? "No images" : "No matches") }
            ForEach(list) { i in
                HStack(spacing: 8) {
                    Image(systemName: i.dangling ? "square.dashed" : "square.stack.3d.up")
                        .foregroundStyle(.secondary).frame(width: 16)
                        .hint(i.dangling ? Help.dangling : "Image \(i.repo):\(i.tag)")
                    VStack(alignment: .leading, spacing: 1) {
                        Text(i.dangling ? "<none>" : i.repo).font(.system(size: 12, weight: .medium))
                            .lineLimit(1).truncationMode(.head)
                        Text("\(i.tag) · \(i.created.formatted(.relative(presentation: .named)))")
                            .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    if i.containers > 0 {
                        Text("in use").font(.system(size: 9, weight: .medium))
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(.green.opacity(0.15), in: Capsule()).foregroundStyle(.green)
                            .hint(Help.inUse)
                    }
                    Text(ByteFormat.bytes(i.size)).font(.system(size: 11).monospacedDigit())
                        .frame(width: 60, alignment: .trailing)
                        .hint(Help.imageSize)
                    Menu {
                        Button("Copy reference") { Pasteboard.copy(i.ref) }
                        if !i.dangling { Button("Pull latest of this tag") { model.run(.imagePull, i.ref) } }
                        Divider()
                        Button("Remove…") { model.run(.imageRemove, i.ref) }
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 22)
                }
                .padding(.vertical, 4).padding(.horizontal, 6)
                .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 6))
            }
        }
    }
}
