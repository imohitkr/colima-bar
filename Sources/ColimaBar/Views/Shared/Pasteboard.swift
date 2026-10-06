import AppKit

enum Pasteboard {
    /// Puts `s` on the general pasteboard as plain text.
    static func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }
}
