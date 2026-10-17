import AppKit
import UniformTypeIdentifiers

/// The Save Diagnostics… and Report an Issue… flows: the save panel, then
/// the model collects and writes the file. `DiagnosticsBundle` has the file rules.
@MainActor
enum DiagnosticsPanel {
    /// Asks where to save the file. Cancel does nothing. A panel gives
    /// ColimaBar access to the chosen folder, so macOS asks no extra
    /// permission for the Desktop. With `report`, the bug report form opens
    /// after the file is saved.
    static func save(model: ColimaModel, report: Bool) {
        guard !model.isSavingDiagnostics else { return }
        model.dismissPopover()
        let panel = NSSavePanel()
        panel.title = report ? "Save Diagnostics and Report an Issue" : "Save Diagnostics"
        panel.message = "Review the file before you share it. ColimaBar can miss a secret."
        panel.nameFieldStringValue = DiagnosticsBundle.fileName(date: Date())
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true
        panel.directoryURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await model.saveDiagnostics(to: url, report: report) }
    }
}
