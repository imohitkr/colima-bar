import AppKit
import UniformTypeIdentifiers

/// The panels and alerts of volume backup and restore. The model does the
/// work. A panel gives ColimaBar access to the file or folder, so macOS asks
/// no extra permission for the Desktop.
@MainActor
enum VolumeBackupPanel {
    /// `UTType.tarArchive` needs macOS 15. The app runs on macOS 14.
    private static let tarType = UTType(filenameExtension: "tar") ?? .data

    // MARK: - Back up

    /// Back Up…: the warning for running containers, then the save panel.
    static func backUp(model: ColimaModel, volume: VolumeRow) {
        guard model.mayStartTransfer() else { return }
        model.dismissPopover()
        Task {
            let running = await model.runningUsers(of: volume.name) ?? []
            if !running.isEmpty, !confirmRunning(volume: volume.name, containers: running) { return }
            let panel = NSSavePanel()
            panel.title = "Back Up Volume"
            panel.message = "ColimaBar saves the files of the volume as a tar archive."
            panel.nameFieldStringValue = VolumeBackupName.fileName(
                volume: volume.name, isAnonymous: volume.isAnonymous, date: Date())
            panel.allowedContentTypes = [tarType]
            panel.canCreateDirectories = true
            panel.directoryURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            NSApp.activate()
            guard panel.runModal() == .OK, let url = panel.url else { return }
            model.backUp(volume: volume, to: url)
        }
    }

    /// Back Up All…: a folder, then one file for each named volume.
    static func backUpAll(model: ColimaModel) {
        guard model.mayStartTransfer() else { return }
        let named = VolumeRow.named(model.volumes)
        guard !named.isEmpty else {
            model.notify("There are no named volumes to back up.")
            return
        }
        model.dismissPopover()
        let panel = NSOpenPanel()
        panel.title = "Back Up All Volumes"
        panel.message = "ColimaBar saves each volume to its own tar archive in this folder."
        panel.prompt = "Back Up"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        NSApp.activate()
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        model.backUpAll(volumes: named, into: folder)
    }

    private static func confirmRunning(volume: String, containers: [String]) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Back up volume \(volume) while containers use it?"
        alert.informativeText =
            "These containers run and can change files during the backup: \(containers.joined(separator: ", ")). For a database, stop them first."
        alert.addButton(withTitle: "Back Up")
        alert.addButton(withTitle: "Cancel").keyEquivalent = "\u{1b}"
        NSApp.activate()
        return alert.runModal() == .alertFirstButtonReturn
    }

    // MARK: - Restore

    /// Restore from Backup…: a file, then a restore into the volume.
    static func restore(model: ColimaModel, volume: VolumeRow) {
        guard model.mayStartTransfer() else { return }
        model.dismissPopover()
        Task {
            guard let file = chooseFile(), let scan = await model.scanBackup(file: file) else { return }
            model.restore(file: file, scan: scan, into: volume.name, confirmReplace: confirmReplace)
        }
    }

    /// Restore to New Volume…: a file, then a name for the new volume.
    static func restoreToNew(model: ColimaModel) {
        guard model.mayStartTransfer() else { return }
        model.dismissPopover()
        Task {
            guard let file = chooseFile(), let scan = await model.scanBackup(file: file) else { return }
            let original = scan.meta?.name
            let suggestion = VolumeBackupName.suggestion(
                original: original, isTaken: original.map(model.isVolumeNameTaken) ?? false)
            guard let name = askNewName(suggestion: suggestion, isTaken: model.isVolumeNameTaken) else { return }
            model.restoreToNew(file: file, scan: scan, name: name)
        }
    }

    private static func chooseFile() -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Restore Volume"
        panel.message = "Choose a tar archive that ColimaBar or docker cp made from a volume."
        panel.prompt = "Restore"
        panel.allowedContentTypes = [tarType]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        NSApp.activate()
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// The question before ColimaBar deletes a volume with files and makes it again.
    private static func confirmReplace(volume: String) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Replace all files in volume \(volume)?"
        alert.informativeText =
            "ColimaBar deletes the volume and creates it again from the backup. The current files are lost for good."
        let replace = alert.addButton(withTitle: "Replace All Files")
        replace.hasDestructiveAction = true
        replace.keyEquivalent = ""  // Return must not delete the data
        alert.addButton(withTitle: "Cancel").keyEquivalent = "\u{1b}"
        NSApp.activate()
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// The form for the name of a new volume. **Restore** works only for a
    /// valid name that no volume has.
    private static func askNewName(suggestion: String, isTaken: @escaping (String) -> Bool) -> String? {
        let alert = NSAlert()
        alert.messageText = "Restore to a new volume"
        alert.informativeText = "Enter a name for the new volume."
        let restore = alert.addButton(withTitle: "Restore")
        alert.addButton(withTitle: "Cancel").keyEquivalent = "\u{1b}"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = suggestion
        field.setAccessibilityLabel("Volume name")
        let isFree = { (text: String) in VolumeBackupName.isValidNewName(text) && !isTaken(text) }
        restore.isEnabled = isFree(suggestion)
        let watcher = TypedNameWatcher(button: restore, matches: isFree)
        field.delegate = watcher
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        NSApp.activate()
        let answer = alert.runModal()
        field.delegate = nil
        guard answer == .alertFirstButtonReturn, isFree(field.stringValue) else { return nil }
        return field.stringValue
    }
}
