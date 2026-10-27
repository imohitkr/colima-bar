import SwiftUI

/// The scan page of one image. It replaces the tabs between the header and
/// the hint bar, so the popover keeps its fixed size. It shows the progress
/// of a scan that runs, or the findings of the last report. The report lives
/// in the model, in memory only.
struct ImageScanView: View {
    let model: ColimaModel
    @Bindable var ui: ViewState
    /// The image ID without `sha256:`.
    let id: String

    private var state: ImageScanState? { model.imageScanState(forImageID: id) }
    private var report: ImageScanReport? { state?.report ?? model.imageScanReport(forImageID: id) }
    private var isRunning: Bool { state?.isRunning == true }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider()
            ScrollView {
                content
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.automatic)
        }
        .onAppear { model.imageScanOnScreen = true }
        .onDisappear { model.imageScanOnScreen = false }
    }

    // MARK: - Bars

    private var name: String {
        state?.imageName ?? report?.imageName ?? String(id.prefix(12))
    }

    private var topBar: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text("Vulnerabilities · \(name)").font(.headline).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 4)
                if isRunning {
                    Button("Cancel") { model.cancelImageScan() }.hint(Help.scanCancel)
                } else if state != nil || report != nil {
                    Button("Scan Again") { model.scanAgain(imageID: id) }
                        .disabled(!model.canScanImages)
                        .hint(model.isDebug ? Help.imageScanDebug : Help.scanAgain)
                }
                Button("Done") { ui.scanImageID = nil }
                    .keyboardShortcut(.cancelAction)
                    .hint(Help.scanDone)
            }
            if let line = headerLine {
                Text(line).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    /// "nginx:latest · Trivy 0.76.1 · 3 min ago"
    private var headerLine: String? {
        if let report {
            let tool = [report.tool.title, report.toolVersion].compactMap { $0 }.joined(separator: " ")
            return [report.imageName, tool, report.date.formatted(.relative(presentation: .named))]
                .joined(separator: " · ")
        }
        return state.map { "\($0.imageName) · \($0.tool.title)" }
    }

    // MARK: - Content

    @ViewBuilder private var content: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let state { progress(state) }
            if let report {
                strip(report)
                list(report)
            } else if state == nil {
                EmptyStateText(text: "No scan yet. Use Scan for Vulnerabilities… in the ••• menu of an image.")
            }
        }
    }

    @ViewBuilder private func progress(_ state: ImageScanState) -> some View {
        if let line = state.statusLine {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    if state.isRunning { ProgressView().controlSize(.small) }
                    Text(line).font(.caption)
                        .foregroundStyle(isFailed(state) ? Color.orange : Color.secondary)
                }
                if case .exporting(let bytes, let total) = state.phase, total > 0 {
                    ProgressView(value: TransferProgress.restoreFraction(sent: bytes, total: total))
                }
            }
        }
    }

    private func isFailed(_ state: ImageScanState) -> Bool {
        if case .failed = state.phase { return true }
        return false
    }

    private func strip(_ report: ImageScanReport) -> some View {
        HStack(spacing: 8) {
            Text(report.summary).font(.system(size: 11, weight: .medium)).lineLimit(1)
                .hint(Help.scanStrip)
            Spacer(minLength: 4)
            // A clean image has nothing to filter.
            if !report.isClean {
                Toggle("Only fixable", isOn: $ui.onlyFixable).toggleStyle(.checkbox).font(.caption)
                    .hint(Help.onlyFixable)
            }
        }
    }

    @ViewBuilder private func list(_ report: ImageScanReport) -> some View {
        let rows = report.rows(onlyFixable: ui.onlyFixable)
        // The severity strip already says "No known vulnerabilities".
        if rows.shown.isEmpty, !report.isClean { EmptyStateText(text: "No finding has a fix.") }
        // Lazy: a long list builds only the rows on screen.
        LazyVStack(alignment: .leading, spacing: 6) {
            ForEach(ImageScanSeverity.allCases.reversed(), id: \.self) { level in
                let group = rows.shown.filter { $0.severity == level }
                if !group.isEmpty {
                    SectionHeader(title: "\(level.title) · \(group.count)")
                    ForEach(group) { ImageScanRow(finding: $0) }
                }
            }
            if rows.hidden > 0 {
                Text("and \(rows.hidden) more").font(.caption).foregroundStyle(.secondary)
                    .hint(Help.scanMore)
            }
        }
    }
}
