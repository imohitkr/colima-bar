import SwiftUI

/// The Doctor page. It replaces the tabs and the stopped screen between the
/// header and the hint bar, so the popover keeps its fixed size.
struct DoctorView: View {
    let model: ColimaModel
    @Bindable var ui: ViewState

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    if let report = model.currentDoctorReport {
                        ForEach(report.results) { DoctorRow(model: model, result: $0) }
                    } else {
                        Text(model.isDoctorRunning ? "Running the checks…" : "No checks yet.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.automatic)
            Divider()
            bottomBar
        }
        .task(id: model.profile) { await model.runDoctorIfStale() }
    }

    private var topBar: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text("Doctor · profile \(model.profile)").font(.headline)
                Spacer()
                if model.isDoctorRunning { ProgressView().controlSize(.small) }
                Button("Run checks") { Task { await model.runDoctor() } }
                    .disabled(model.isDoctorRunning)
                    .hint(Help.doctorRun)
                Button("Done") { ui.showDoctor = false }
                    .hint(Help.doctorDone)
            }
            if let report = model.currentDoctorReport {
                Text("\(report.summary) · \(report.date.formatted(date: .omitted, time: .shortened))")
                    .font(.caption).foregroundStyle(report.problems > 0 ? .red : .secondary)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private var bottomBar: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Button("Repair profile '\(model.profile)'…") { model.applyFix(.repair) }
                    .disabled(!canRepair)
                    .hint(model.isDebug ? Help.doctorDebug : Help.doctorRepair)
                Text(model.config == nil ? "This profile has no colima.yaml." : "Use it when the VM does not start.")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 0)
            }
            HStack(spacing: 8) {
                Button("Save Diagnostics…") { DiagnosticsPanel.save(model: model, report: false) }
                    .disabled(model.isSavingDiagnostics)
                    .hint(Help.saveDiagnostics)
                Button("Report an Issue…") { DiagnosticsPanel.save(model: model, report: true) }
                    .disabled(model.isSavingDiagnostics)
                    .hint(Help.reportIssue)
                if model.isSavingDiagnostics { ProgressView().controlSize(.small) }
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private var canRepair: Bool {
        !model.isDebug && !model.isDoctorRunning && model.busy == nil && model.config != nil
    }
}
