import AppKit
import SwiftUI

/// The notice for a VM type change that did not finish, for example after
/// ColimaBar quit during it. It shows the journal of the selected profile and
/// what is left to do. **Restore Backups…** copies the backups into the new
/// VM. It restores only what is missing.
struct VMRecreateNotice: View {
    let model: ColimaModel

    var body: some View {
        if let journal = model.pendingRecreate[model.profile],
            let recovery = VMRecreateJournal.recovery(journal, now: model.vmSettings, busy: false)
        {
            VStack(alignment: .leading, spacing: 6) {
                Text(Self.text(journal, recovery))
                    .font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    if recovery == .restorePending, model.state == .running, !journal.folder.isEmpty {
                        Button("Restore Backups…") { restore(journal) }
                            .controlSize(.mini).disabled(model.recreate != nil || model.isDebug)
                            .hint(Help.recreateRestore)
                    }
                    if !journal.folder.isEmpty, FileManager.default.fileExists(atPath: journal.folder) {
                        Button("Show Folder") {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: journal.folder)])
                        }
                        .controlSize(.mini).hint(Help.recreateShowFolder)
                    }
                    Button("Dismiss") { model.dismissRecreate(journal.profile) }
                        .controlSize(.mini).disabled(model.recreate != nil || model.isDebug)
                        .hint(model.isDebug ? Help.doctorDebug : Help.recreateDismiss)
                }
            }
            .padding(.vertical, 6).padding(.horizontal, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
        }
    }

    static func text(_ j: VMRecreateJournal, _ recovery: VMRecreateJournal.Recovery) -> String {
        switch recovery {
        case .nothingChanged:
            "A VM type change of profile \(j.profile) stopped before it changed the VM. Nothing changed."
        case .restorePending:
            "A VM type change of profile \(j.profile) did not finish."
                + (j.folder.isEmpty ? "" : " The backups are in \(j.folderName).")
        case .configMissing:
            "A VM type change of profile \(j.profile) did not finish. colima.yaml is missing. A copy is in ~/.cache/colima-bar/colima.\(j.profile).yaml.recreate."
        }
    }

    /// The folder panel starts in the backup folder. The user's pick gives
    /// ColimaBar access to the folder again after a relaunch.
    private func restore(_ journal: VMRecreateJournal) {
        let p = journal.profile
        model.dismissPopover()
        let panel = NSOpenPanel()
        panel.title = "Restore Backups"
        panel.message = "Choose the backup folder of the VM type change."
        panel.prompt = "Restore"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: journal.folder)
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url, p == model.profile else { return }
        model.resumeRecreate(p, folder: url)
    }
}
