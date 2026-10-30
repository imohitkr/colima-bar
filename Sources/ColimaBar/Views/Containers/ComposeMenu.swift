import AppKit
import SwiftUI

/// The remove button and the ••• menu in the header of a Compose project:
/// open the folder, and pull, start or remove the project with
/// `docker compose`.
struct ComposeMenu: View {
    let model: ColimaModel
    let project: ComposeProject
    /// No container of the project runs. Only then the header shows the
    /// remove button, like a container row.
    var stopped = false

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
            if stopped {
                IconButton("trash", reason ?? Help.composeRemove) { model.compose(.remove, project: project) }
                    .disabled(reason != nil)
            }
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
                if model.projectNeedsUpdate(project.name) {
                    Button("Update and Recreate") { model.updateAndRecreate(project: project) }
                        .disabled(reason != nil || !model.canPullImages)
                        .hint(model.isDebug ? Help.imageUpdateDebug : Help.composeUpdateRecreate)
                }
                Button("Up (Detached)") { model.compose(.up, project: project) }
                    .disabled(reason != nil).hint(Help.composeUp)
                Button("Down…") { model.compose(.down, project: project) }
                    .disabled(reason != nil).hint(Help.composeDown)
                Button("Remove Project…") { model.compose(.remove, project: project) }
                    .disabled(reason != nil).hint(Help.composeRemove)
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

    /// Why Pull, Up, Down and Remove do not run now. It is also the hint of the menu.
    private func disabledReason(missing: Bool, noDocker: Bool) -> String? {
        if model.isDebug { return Help.composeDebug }
        if noDocker { return Help.composeNoDocker }
        if missing { return Help.composeMoved }
        if busy { return Help.composeRunning }
        return nil
    }
}
