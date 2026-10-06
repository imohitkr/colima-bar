import SwiftUI

struct IconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void

    init(_ symbol: String, _ help: String, action: @escaping () -> Void) {
        self.symbol = symbol
        self.help = help
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).frame(width: 22, height: 20).contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .hint(help)
        .accessibilityLabel(String(help.split(separator: ".").first ?? Substring(help)))
    }
}
