import Observation

/// Picker selections live in an @Observable object, not @State: the SwiftUI
/// macro plugin isn't shipped with Command Line Tools, Observation's is.
@MainActor @Observable
final class SystemForm {
    var cpu = 0
    var mem = 0
    var loginEnabled = LoginItem.isEnabled
    var loginNeedsApproval = false  // filled in off the main thread (runs launchctl)
    var linking = false
    var customIdle = false  // "Custom" picked in the auto-stop picker
    var customMinutes = ""
}
