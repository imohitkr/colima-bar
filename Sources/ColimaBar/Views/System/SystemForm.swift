import Observation

/// Picker selections live in an @Observable object, not @State: the SwiftUI
/// macro plugin isn't shipped with Command Line Tools, Observation's is.
@MainActor @Observable
final class SystemForm {
    var cpu = 0
    /// GiB, the exact value: a CPU-only Apply sends the memory unchanged.
    var mem = 0.0
    var loginEnabled = LoginItem.isEnabled
    var loginNeedsApproval = false  // filled in off the main thread (runs launchctl)
    var isLinking = false
    var isCustomIdle = false  // "Custom" picked in the auto-stop picker
    var customMinutes = ""
}
