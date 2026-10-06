import SwiftUI

struct FooterView: View {
    let model: ColimaModel
    let inWindow: Bool
    let openWindow: () -> Void

    var body: some View {
        HStack(spacing: 2) {
            IconButton("terminal", Help.ssh) { model.terminal("ssh") }
            IconButton("doc.on.clipboard", Help.copyEnv) {
                model.ctl("copy-env")
                Hint.shared.text = "Copied the DOCKER_HOST export to the clipboard."
            }
            IconButton("doc.text", Help.config) { model.ctl("config") }
            IconButton("list.bullet.rectangle", Help.log) { model.ctl("logs") }
            Spacer()
            Button {
                Task { await Updater.shared.check(manual: true) }
            } label: {
                Text("v\(AppDelegate.version)").font(.caption2.monospacedDigit())
                    .lineLimit(1).truncationMode(.middle).frame(maxWidth: 120)
            }
            .buttonStyle(.borderless).foregroundStyle(.secondary)
            .hint(Help.version(AppDelegate.version))
            if let r = Updater.shared.available {
                Button {
                    Updater.shared.openReleasePage()
                } label: {
                    Label("Update \(r.version)", systemImage: "arrow.down.circle.fill")
                        .font(.caption.weight(.medium))
                }
                .buttonStyle(.borderless).foregroundStyle(Color.accentColor)
                .hint(Help.update(r.version))
            }
            if !inWindow {
                IconButton("macwindow", Help.window) { openWindow() }
            }
            IconButton("arrow.clockwise.circle", Help.refresh) { Task { await model.refreshAll() } }
            IconButton("power", Help.quit) { NSApp.terminate(nil) }
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
    }
}
