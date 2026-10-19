import AppKit
import SwiftUI

/// The ••• menu in the header of a Compose project: open the folder, and
/// pull, start or remove the project with `docker compose`.
struct ComposeMenu: View {
    let model: ColimaModel
    let project: ComposeProject

    private static let vsCodeID = "com.microsoft.VSCode"

    private var folder: URL { URL(fileURLWithPath: project.directory, isDirectory: true) }
    private var busy: Bool { model.composeBusy.contains(model.composeKey(project)) }

    var body: some View {
        let reason = disabledReason(
            missing: model.composeMissing.contains(model.composeKey(project)), noDocker: model.composeNoDocker)
        let vsCode = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.vsCodeID)
        let output = model.composeOutput[model.composeKey(project)] ?? []
        HStack(spacing: 2) {
            if busy { ProgressView().controlSize(.small).hint(Help.composeRunning) }
            Menu {
                Button("Open Project Folder") { NSWorkspace.shared.open(folder) }
                    .disabled(model.composeMissing.contains(model.composeKey(project)))
                    .hint(Help.openProjectFolder)
                if let vsCode {
                    Button("Open in VS Code") {
                        NSWorkspace.shared.open(
                            [folder], withApplicationAt: vsCode, configuration: NSWorkspace.OpenConfiguration())
                    }
                    .hint(Help.vsCode)
                }
                Button("Copy Project Path") { Pasteboard.copy(project.directory) }
                    .hint(Help.copyProjectPath)
                Divider()
                Button("Pull Images") { model.compose(.pull, project: project) }
                    .disabled(reason != nil).hint(Help.composePull)
                Button("Up (Detached)") { model.compose(.up, project: project) }
                    .disabled(reason != nil).hint(Help.composeUp)
                Button("Down…") { model.compose(.down, project: project) }
                    .disabled(reason != nil).hint(Help.composeDown)
                if !output.isEmpty {
                    Divider()
                    Button("Copy Last Output") { Pasteboard.copy(output.joined(separator: "\n")) }
                        .hint(Help.composeOutput)
                }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 22)
            .accessibilityLabel("Compose actions for \(project.name)")
            .hint(reason ?? Help.composeMenu)
        }
    }

    /// Why Pull, Up and Down do not run now. It is also the hint of the menu.
    private func disabledReason(missing: Bool, noDocker: Bool) -> String? {
        if model.isDebug { return Help.composeDebug }
        if noDocker { return Help.composeNoDocker }
        if missing { return Help.composeMoved }
        if busy { return Help.composeRunning }
        return nil
    }
}
