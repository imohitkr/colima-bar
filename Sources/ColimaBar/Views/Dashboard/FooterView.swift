import SwiftUI

struct FooterView: View {
    let model: ColimaModel
    let inWindow: Bool
    let openWindow: () -> Void

    var body: some View {
        HStack(spacing: 2) {
            IconButton("terminal", Help.ssh) { model.terminal(.ssh) }
            IconButton("doc.on.clipboard", Help.copyEnv) {
                model.run(.copyEnv)
                Hint.shared.text = "Copied the DOCKER_HOST export to the clipboard."
            }
            IconButton("doc.text", Help.config) { model.run(.config) }
            IconButton("list.bullet.rectangle", Help.log) { model.run(.logs) }
            Spacer()
            Button {
                // A manual check always ends with an alert; the popover would cover it.
                model.dismissPopover()
                Task { await Updater.shared.check(manual: true) }
            } label: {
                Text("v\(AppDelegate.version)").font(.caption2.monospacedDigit())
                    .lineLimit(1).truncationMode(.middle).frame(maxWidth: 120)
            }
            .buttonStyle(.borderless).foregroundStyle(.secondary)
            .hint(Help.version(AppDelegate.version))
            if let r = Updater.shared.available {
                UpdateButton(release: r, model: model)
            } else if let note = Updater.shared.macOSNote {
                Text(note).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
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

/// The update button in the footer: Install or Update, then the progress.
private struct UpdateButton: View {
    let release: ReleaseInfo
    let model: ColimaModel

    var body: some View {
        let updater = Updater.shared
        switch updater.phase {
        case .idle:
            let offer = updater.offer
            Button {
                // The dialogs are modal; the popover would cover them.
                model.dismissPopover()
                Task { await updater.startUpdate() }
            } label: {
                Label(
                    offer == .install ? "Install \(release.version)" : "Update \(release.version)",
                    systemImage: "arrow.down.circle.fill"
                )
                .font(.caption.weight(.medium))
            }
            .buttonStyle(.borderless).foregroundStyle(Color.accentColor)
            .hint(hint(offer))
        case .downloading(let share):
            ProgressView(value: share).progressViewStyle(.linear).frame(width: 60)
            cancel
        case .verifying:
            Text("Checking…").font(.caption).foregroundStyle(.secondary).hint(Help.updateChecking)
            cancel
        case .waiting(let why):
            Text("Waiting…").font(.caption).foregroundStyle(.secondary).hint(Help.updateWaiting(why))
            cancel
        case .installing:
            Text("Installing…").font(.caption).foregroundStyle(.secondary).hint(Help.updateInstalling)
        }
    }

    private var cancel: some View {
        IconButton("xmark.circle", Help.cancelUpdate) { Updater.shared.cancel() }
    }

    private func hint(_ offer: Updater.Offer) -> String {
        switch offer {
        case .install: Help.install(release.version)
        case .homebrew: Help.brewUpdate(release.version)
        case .link(let why): Help.updateLink(release.version, reason: why)
        }
    }
}
