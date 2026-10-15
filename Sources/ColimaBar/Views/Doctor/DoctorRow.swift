import SwiftUI

/// One check in the Doctor list: a status icon, the title, the detail and,
/// when there is one, a small button for the fix.
struct DoctorRow: View {
    let model: ColimaModel
    let result: DoctorResult

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol).foregroundStyle(color).frame(width: 16)
                .accessibilityLabel(statusText)
            VStack(alignment: .leading, spacing: 2) {
                Text(result.check.title).font(.system(size: 12, weight: .semibold))
                Text(result.detail).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            if let fix = result.fix {
                Button(fix.label) { model.applyFix(fix) }
                    .controlSize(.mini)
                    .disabled(model.isDoctorRunning || model.busy != nil || model.isDebug)
                    .hint(model.isDebug ? Help.doctorDebug : Help.doctorFix(fix))
            }
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .hint(Help.doctorCheck(result.check) + " " + result.detail)
    }

    private var symbol: String {
        switch result.status {
        case .ok: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .problem: "xmark.octagon.fill"
        case .skipped: "minus.circle"
        }
    }

    private var color: Color {
        switch result.status {
        case .ok: .green
        case .warning: .orange
        case .problem: .red
        case .skipped: .secondary
        }
    }

    private var statusText: String {
        switch result.status {
        case .ok: "OK"
        case .warning: "Warning"
        case .problem: "Problem"
        case .skipped: "Skipped"
        }
    }
}
