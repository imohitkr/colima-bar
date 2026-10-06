import SwiftUI

struct SectionHeader<Trailing: View>: View {
    let title: String
    var collapsed: Binding<Bool>? = nil
    var hint: String? = nil
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 4) {
            if let collapsed {
                Button {
                    collapsed.wrappedValue.toggle()
                } label: {
                    Image(systemName: collapsed.wrappedValue ? "chevron.right" : "chevron.down")
                        .font(.caption2.weight(.bold)).frame(width: 12)
                    Text(title).font(.caption.weight(.semibold))
                }
                .buttonStyle(.plain)
            } else {
                Text(title).font(.caption.weight(.semibold))
            }
            if let hint {
                Image(systemName: "info.circle").font(.caption2).foregroundStyle(.tertiary).hint(hint)
            }
            Spacer()
            trailing
        }
        .foregroundStyle(.secondary)
        .padding(.top, 4)
    }
}

extension SectionHeader where Trailing == EmptyView {
    init(title: String) { self.init(title: title, trailing: { EmptyView() }) }
}
