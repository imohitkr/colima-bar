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
    /// The Cleanup page replaces the tabs and the stopped screen.
    var showCleanup = false
    /// The container that the Inspect page shows. The page replaces the
    /// tabs while the VM runs. It never keeps a value of the container.
    var inspectID: String? {
        didSet { if inspectID != oldValue { inspect.reset() } }
    }
    /// The image that the scan page shows (an ID without `sha256:`). The page
    /// replaces the tabs while the VM runs. The findings stay in the model.
    var scanImageID: String?
    /// The scan page lists only the findings that have a fix.
    var onlyFixable = false
    let inspect = InspectState()
    let system = SystemForm()
    let vmConfig = VMConfigForm()
}
