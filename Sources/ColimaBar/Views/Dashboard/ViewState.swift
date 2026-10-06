import SwiftUI

enum Tab: String, CaseIterable, Identifiable {
    case containers = "Containers", images = "Images", volumes = "Volumes", system = "System"
    var id: String { rawValue }
}

/// UI state that must survive the popover closing and reopening.
@MainActor @Observable
final class ViewState {
    var tab: Tab = .containers
    var search = ""
    var runningOnly = false
    var collapsed: Set<String> = []
    let system = SystemForm()
}
