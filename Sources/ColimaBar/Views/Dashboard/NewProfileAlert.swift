import AppKit

/// The New Profile form: name, CPU, memory, disk, runtime, VM type and mount type. The values
/// start with the ones of the selected profile. The Create button works
/// only while the form is valid (see NewProfileForm.problem).
@MainActor
enum NewProfileAlert {
    /// The form, or nil if the user cancelled.
    static func run(defaults: NewProfileForm, existing: [String]) -> NewProfileForm? {
        let alert = NSAlert()
        alert.messageText = "New Colima profile"
        alert.informativeText =
            "ColimaBar creates the profile with colima start and starts its VM. A docker profile gets its own profile socket and the docker context colimabar-NAME."
        let create = alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel").keyEquivalent = "\u{1b}"

        let name = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        name.placeholderString = "work"
        name.setAccessibilityLabel("Profile name")
        let hostCPUs = ProcessInfo.processInfo.activeProcessorCount
        let hostGB = Int(ProcessInfo.processInfo.physicalMemory / UInt64(ByteFormat.bytesPerGiB))
        let cpu = popup(
            NewProfileForm.choices(NewProfileForm.cpuChoices, limit: hostCPUs, including: defaults.cpus),
            selected: defaults.cpus, unit: "CPU")
        let mem = popup(
            NewProfileForm.choices(NewProfileForm.memoryChoices, limit: hostGB, including: defaults.memGB),
            selected: defaults.memGB, unit: "GB")
        let disk = popup(
            NewProfileForm.choices(NewProfileForm.diskChoices, limit: .max, including: defaults.diskGB),
            selected: defaults.diskGB, unit: "GB")
        let runtime = NSPopUpButton(frame: .zero, pullsDown: false)
        runtime.addItems(withTitles: NewProfileForm.runtimes)
        runtime.selectItem(withTitle: defaults.runtime)
        let vmType = NSPopUpButton(frame: .zero, pullsDown: false)
        vmType.addItems(withTitles: VMTypeRules.vmTypes)
        vmType.selectItem(withTitle: defaults.vmType)
        vmType.toolTip = Help.newProfileVMType
        let mountType = NSPopUpButton(frame: .zero, pullsDown: false)
        mountType.toolTip = Help.newProfileMountType
        func fillMountTypes() {
            let items = VMTypeRules.mountTypes(for: vmType.titleOfSelectedItem ?? "vz")
            mountType.removeAllItems()
            mountType.addItems(withTitles: items)
        }
        fillMountTypes()
        mountType.selectItem(withTitle: defaults.mountType)
        let problem = NSTextField(wrappingLabelWithString: "")
        problem.textColor = .secondaryLabelColor
        problem.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        problem.preferredMaxLayoutWidth = 280

        let grid = NSGridView(views: [
            [NSTextField(labelWithString: "Name:"), name],
            [NSTextField(labelWithString: "CPU:"), cpu],
            [NSTextField(labelWithString: "Memory:"), mem],
            [NSTextField(labelWithString: "Disk:"), disk],
            [NSTextField(labelWithString: "Runtime:"), runtime],
            [NSTextField(labelWithString: "VM type:"), vmType],
            [NSTextField(labelWithString: "Mount type:"), mountType],
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.rowSpacing = 8
        let stack = NSStackView(views: [grid, problem])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.frame = NSRect(x: 0, y: 0, width: 300, height: 200)

        func form() -> NewProfileForm {
            NewProfileForm(
                name: name.stringValue.trimmingCharacters(in: .whitespaces),
                cpus: cpu.selectedTag(), memGB: mem.selectedTag(), diskGB: disk.selectedTag(),
                runtime: runtime.titleOfSelectedItem ?? "docker", vmType: vmType.titleOfSelectedItem ?? "vz",
                mountType: mountType.titleOfSelectedItem ?? "")
        }
        let qemu = VMTypeRules.qemuInstalled(arch: "")
        let watcher = FormWatcher {
            let p = form().problem(existing: existing, qemuInstalled: qemu)
            create.isEnabled = p == nil
            problem.stringValue = p ?? " "
        }
        name.delegate = watcher
        for control in [cpu, mem, disk, runtime, mountType] {
            control.target = watcher
            control.action = #selector(FormWatcher.changed(_:))
        }
        // A new VM type fills the mount types again and picks the default.
        vmType.target = watcher
        vmType.action = #selector(FormWatcher.changed(_:))
        watcher.beforeUpdate = { sender in if sender === vmType { fillMountTypes() } }
        watcher.update()
        alert.accessoryView = stack
        alert.window.initialFirstResponder = name

        NSApp.activate()
        let answer = alert.runModal()
        name.delegate = nil
        let result = form()
        guard answer == .alertFirstButtonReturn, result.problem(existing: existing, qemuInstalled: qemu) == nil else {
            return nil
        }
        return result
    }

    /// A menu of numbers. Each item's tag is its number.
    private static func popup(_ values: [Int], selected: Int, unit: String) -> NSPopUpButton {
        let b = NSPopUpButton(frame: .zero, pullsDown: false)
        for v in values {
            b.addItem(withTitle: "\(v) \(unit)")
            b.lastItem?.tag = v
        }
        b.selectItem(withTag: selected)
        return b
    }
}

/// Checks the form again after each change.
@MainActor
private final class FormWatcher: NSObject, NSTextFieldDelegate {
    let update: () -> Void
    /// Runs before the check, with the control that changed.
    var beforeUpdate: (AnyObject?) -> Void = { _ in }

    init(_ update: @escaping () -> Void) { self.update = update }

    func controlTextDidChange(_ note: Notification) { update() }

    @objc func changed(_ sender: Any?) {
        beforeUpdate(sender as AnyObject?)
        update()
    }
}
