import SwiftUI

enum DashboardTab: String, CaseIterable, Identifiable {
    case containers = "Containers", images = "Images", volumes = "Volumes", system = "System"
    var id: String { rawValue }
}

/// UI state that must survive the popover closing and reopening.
@MainActor @Observable
final class ViewState {
    var tab: DashboardTab = .containers
    var search = ""
    var runningOnly = false
    var collapsed: Set<String> = []
    /// The Doctor page replaces the tabs and the stopped screen.
    var showDoctor = false
    /// The VM settings page replaces the tabs and the stopped screen.
    var showVMConfig = false
    let system = SystemForm()
    let vmConfig = VMConfigForm()
}
