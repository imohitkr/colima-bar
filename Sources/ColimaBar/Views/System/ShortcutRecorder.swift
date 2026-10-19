import SwiftUI

/// The row in the System tab for the dashboard shortcut.
struct ShortcutRecorder: View {
    var recording: ShortcutRecording
    private let hotKey = HotKey.shared

    private var title: String {
        if recording.isRecording {
            return recording.held.isEmpty ? "Press Shortcut…" : recording.held + "…"
        }
        return hotKey.combo?.display ?? "Record Shortcut"
    }

    private var value: String {
        if recording.isRecording { return "Recording. Press the shortcut, or press Escape to cancel." }
        return hotKey.combo?.spoken ?? "None"
    }

    private var hint: String {
        if AppDelegate.isDebugRun { return Help.shortcutDebug }
        return recording.isRecording ? Help.shortcutRecording : Help.shortcut
    }

    /// The line under the row, and its color.
    private var note: (text: String, warning: Bool)? {
        if let m = recording.message { return (m, true) }
        if recording.isRecording { return ("Press Esc to cancel.", false) }
        if let combo = hotKey.combo, let p = hotKey.problem {
            return ("\(combo.display) does not work. \(p.message)", true)
        }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text("Keyboard shortcut for the dashboard")
                Spacer()
                Button(title) { recording.toggle() }
                    .controlSize(.small)
                    .accessibilityLabel("Keyboard shortcut for the dashboard")
                    .accessibilityValue(value)
                    .hint(hint)
                if hotKey.combo != nil, !recording.isRecording {
                    Button {
                        _ = hotKey.set(nil)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Remove keyboard shortcut")
                    .hint(Help.shortcutClear)
                }
            }
            if let note {
                Text(note.text)
                    .font(.caption2)
                    .foregroundStyle(note.warning ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
            }
        }
        .disabled(AppDelegate.isDebugRun)
        .onDisappear { recording.cancel() }
    }
}
