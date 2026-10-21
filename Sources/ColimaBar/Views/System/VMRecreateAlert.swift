import AppKit

/// The in-app warning before a VM type change. The user must type the profile
/// name before the destructive button works, and Return does not confirm.
/// colima-ctl.sh asks one more time before it deletes anything.
@MainActor
enum VMRecreateAlert {
    struct Choice {
        let backUp: Bool
        let saveImages: Bool
        /// The folder that the user chose for the backups, or nil if there are none.
        let parent: URL?
    }

    /// Asks, then asks for the backup folder if a backup is on. Nil if the user
    /// cancelled, or if the folder has too little space.
    static func confirm(model: ColimaModel, vmType: String, mountType: String) -> Choice? {
        let inputs = model.recreateInputs(vmType: vmType, mountType: mountType)
        let plan = VMRecreatePlan.make(inputs)
        let profile = inputs.profile
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Delete and recreate the VM of profile \(profile)?"
        alert.informativeText = VMRecreatePlan.warning(inputs, plan: plan)
        let destroy = alert.addButton(withTitle: "Delete and Recreate")
        destroy.hasDestructiveAction = true
        destroy.isEnabled = false
        destroy.keyEquivalent = ""  // Return must not delete the VM
        alert.addButton(withTitle: "Cancel").keyEquivalent = "\u{1b}"

        let volumes = checkbox(
            "Back up all named volumes (\(plan.volumes.count), about \(ByteFormat.bytes(plan.volumeBytes)))",
            on: plan.backUpByDefault, enabled: plan.canBackUp && !plan.volumes.isEmpty)
        let images = checkbox(
            "Save the images that containers use (\(plan.imageRefs.count), about \(ByteFormat.bytes(plan.imageBytes)))",
            on: plan.saveImagesByDefault, enabled: plan.canBackUp && !plan.imageRefs.isEmpty)
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = profile
        field.setAccessibilityLabel("Profile name")
        let watcher = TypedNameWatcher(button: destroy) { VMRecreatePlan.confirms(typed: $0, profile: profile) }
        field.delegate = watcher
        let stack = NSStackView(views: [volumes, images, field])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.frame = NSRect(x: 0, y: 0, width: 380, height: 100)
        alert.accessoryView = stack
        alert.window.initialFirstResponder = field

        NSApp.activate()
        let clicked = alert.runModal()
        field.delegate = nil
        let answer = VMRecreatePlan.answer(
            clicked: clicked.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue,
            typedOK: VMRecreatePlan.confirms(typed: field.stringValue, profile: profile),
            backUp: volumes.state == .on && volumes.isEnabled, saveImages: images.state == .on && images.isEnabled)
        guard case .recreate(let backUp, let saveImages) = answer else { return nil }
        guard backUp || saveImages else { return Choice(backUp: false, saveImages: false, parent: nil) }
        guard let parent = chooseFolder() else {
            model.notify("Cancelled. Nothing changed.")
            return nil
        }
        let needed = plan.neededBytes(backUp: backUp, saveImages: saveImages)
        if let free = freeBytes(in: parent), free < needed {
            model.notify(
                "The folder has \(ByteFormat.bytes(Double(free))) free. The backups need about \(ByteFormat.bytes(Double(needed))). Choose another folder or free space."
            )
            return nil
        }
        return Choice(backUp: backUp, saveImages: saveImages, parent: parent)
    }

    private static func checkbox(_ title: String, on: Bool, enabled: Bool) -> NSButton {
        let b = NSButton(checkboxWithTitle: title, target: nil, action: nil)
        b.state = on && enabled ? .on : .off
        b.isEnabled = enabled
        return b
    }

    /// The folder panel. It starts on the Desktop, like Back Up All.
    private static func chooseFolder() -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Choose a folder for the backups"
        panel.message = "ColimaBar makes a new folder in it for this change."
        panel.prompt = "Choose"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        NSApp.activate()
        return panel.runModal() == .OK ? panel.url : nil
    }

    private static func freeBytes(in folder: URL) -> Int64? {
        let values = try? folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }
}
