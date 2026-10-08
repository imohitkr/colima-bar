import SwiftUI

/// The dashboard while the VM does not run. For a stopped VM, it shows the
/// Start button and the VM settings from colima.yaml. A change there only
/// edits colima.yaml, and it applies at the next start.
struct StoppedView: View {
    @Bindable var model: ColimaModel
    @Bindable var form: SystemForm

    var body: some View {
        if model.state == .stopped {
            stopped
        } else {
            VStack(spacing: 14) {
                Spacer()
                Image(systemName: "shippingbox").font(.system(size: 44)).foregroundStyle(.secondary)
                Text(title).font(.title3)
                if model.state == .notInstalled {
                    Text("Install it with Homebrew, then reopen this menu:").foregroundStyle(.secondary)
                    Text("brew install colima docker").font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                }
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// The Start block on top, then the VM settings. The settings scroll, so
    /// the popover keeps its fixed size.
    private var stopped: some View {
        ScrollView {
            VStack(spacing: 10) {
                Image(systemName: "shippingbox").font(.system(size: 32)).foregroundStyle(.secondary)
                Text(title).font(.title3)
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
                .hint(Help.startVM)
                // Reachable while stopped: the System tab only shows while running.
                Toggle("Hide menu bar icon while Colima is stopped", isOn: $model.hideIconWhenStopped)
                    .toggleStyle(.checkbox).controlSize(.small)
                    .hint(Help.hideIcon)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 16).padding(.bottom, 4)
            Divider()
            Group {
                if model.config != nil {
                    VMSettingsSection(model: model, form: form, running: false)
                        .disabled(model.busy != nil)
                } else {
                    Text("This profile has no colima.yaml. Start it once to create one.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.automatic)
    }

    private var title: String {
        switch model.state {
        case .unknown: return "Checking Colima…"
        case .notInstalled: return "Colima isn't installed"
        default: return "Colima (\(model.profile)) is stopped"
        }
    }
}
