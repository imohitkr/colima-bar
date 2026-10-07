import AppKit
import UniformTypeIdentifiers

/// The Export Settings… and Import Settings… flows: the file panels, the
/// confirmation and the summary. `SettingsTransfer` has the file rules.
@MainActor
enum SettingsFilePanel {
    static func export(model: ColimaModel) {
        let panel = NSSavePanel()
        panel.title = "Export Settings"
        panel.nameFieldStringValue = SettingsTransfer.fileName
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try SettingsTransfer.encode(model.settingsSnapshot, appVersion: AppDelegate.version)
            try data.write(to: url, options: .atomic)
        } catch {
            alert("Couldn't export the settings", error.localizedDescription)
        }
    }

    static func importFile(model: ColimaModel, form: SystemForm) {
        let panel = NSOpenPanel()
        panel.title = "Import Settings"
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let plan: SettingsTransfer.Plan
        do {
            let size = (try url.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0
            guard size <= SettingsTransfer.maxBytes else {
                alert("Couldn't import the settings", SettingsTransfer.Failure.tooLarge.message)
                return
            }
            // Read at most one byte more than the limit, so a file that grew
            // after the size check is not loaded whole. decode refuses it.
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let data = try handle.read(upToCount: SettingsTransfer.maxBytes + 1) ?? Data()
            plan = try SettingsTransfer.plan(data, current: model.settingsSnapshot, profiles: model.profileNames)
        } catch let failure as SettingsTransfer.Failure {
            alert("Couldn't import the settings", failure.message)
            return
        } catch {
            alert("Couldn't import the settings", error.localizedDescription)
            return
        }

        guard !plan.changes.isEmpty else {
            alert("Nothing to change", text(["The file has no new settings."], skipped: plan.skipped))
            return
        }
        let a = NSAlert()
        a.messageText = "Apply \(plan.changes.count) setting\(plan.changes.count == 1 ? "" : "s")?"
        a.informativeText = text(section("These settings change:", plan.changes.map(\.text)), skipped: plan.skipped)
        a.addButton(withTitle: "Apply")
        a.addButton(withTitle: "Cancel")
        NSApp.activate()
        guard a.runModal() == .alertFirstButtonReturn else { return }

        var applied: [String] = []
        var skipped = plan.skipped
        for change in plan.changes {
            if let note = model.apply(change) {
                skipped.append(note)
            } else {
                applied.append(change.text)
            }
        }
        form.loginEnabled = LoginItem.isEnabled
        alert(
            applied.isEmpty ? "No settings changed" : "Settings imported",
            text(applied.isEmpty ? [] : section("Applied:", applied), skipped: skipped))
    }

    /// A title line and one bullet line for each item.
    private static func section(_ title: String, _ items: [String]) -> [String] {
        [title] + items.map { "• \($0)" }
    }

    /// The lines, then the skipped items after an empty line.
    private static func text(_ lines: [String], skipped: [String]) -> String {
        var all = lines
        if !skipped.isEmpty { all += (all.isEmpty ? [] : [""]) + section("Skipped:", skipped) }
        return all.joined(separator: "\n")
    }

    private static func alert(_ title: String, _ text: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        NSApp.activate()
        a.runModal()
    }
}
