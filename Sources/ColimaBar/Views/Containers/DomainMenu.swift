import SwiftUI

/// The globe in the header of a Compose project: a menu of the names of its
/// services.
struct DomainMenu: View {
    let model: ColimaModel
    let names: [String]

    var body: some View {
        Menu {
            ForEach(names, id: \.self) { rel in
                Button(DomainLink.host(relative: rel, suffix: model.primaryDomainSuffix)) { model.openDomain(rel) }
            }
        } label: {
            Image(systemName: "globe")
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 22)
        .accessibilityLabel("Container domains of this project")
        .hint(Help.domainMenu)
    }
}
