import SwiftUI

struct StoppedView: View {
    @Bindable var model: ColimaModel

    var body: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "shippingbox").font(.system(size: 44)).foregroundStyle(.secondary)
            Text(title).font(.title3)
            if model.state == .notInstalled {
                Text("Install it with Homebrew, then reopen this menu:").foregroundStyle(.secondary)
                Text("brew install colima docker").font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
            }
            if model.state == .stopped {
                if model.autoStart {
                    Text("It will start by itself when something uses docker.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Button {
                    model.run(.start)
                } label: {
                    Label("Start Colima", systemImage: "play.fill").frame(width: 160)
                }
                .controlSize(.large).buttonStyle(.borderedProminent)
                .disabled(model.busy != nil)
                // Reachable while stopped: the System tab only shows while running.
                Toggle("Hide menu bar icon while Colima is stopped", isOn: $model.hideIconWhenStopped)
                    .toggleStyle(.checkbox).controlSize(.small)
                    .hint(Help.hideIcon)
                    .padding(.top, 6)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var title: String {
        switch model.state {
        case .unknown: return "Checking Colima…"
        case .notInstalled: return "Colima isn't installed"
        default: return "Colima (\(model.profile)) is stopped"
        }
    }
}
