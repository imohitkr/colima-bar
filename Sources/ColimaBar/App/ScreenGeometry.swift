import AppKit

/// Where a screen is and which part of its top edge the camera housing
/// covers. A plain value, so tests can build screens of any shape.
struct ScreenGeometry: Equatable, Sendable {
    let frame: CGRect
    /// The parts of the top edge beside the camera housing, or nil for a
    /// screen without one.
    let topLeft: CGRect?
    let topRight: CGRect?

    /// An empty area counts as no area: NSScreen gives an empty rect, not
    /// nil, for a screen without a camera housing. The header of NSScreen does
    /// not say whether the areas are global or relative to the screen. An
    /// area that is not inside the frame is therefore moved by the origin of
    /// the frame. On a screen at (0, 0) both readings are the same.
    init(frame: CGRect, topLeft: CGRect? = nil, topRight: CGRect? = nil) {
        self.frame = frame
        self.topLeft = Self.global(topLeft, in: frame)
        self.topRight = Self.global(topRight, in: frame)
    }

    nonisolated static func global(_ area: CGRect?, in frame: CGRect) -> CGRect? {
        guard let area, !area.isEmpty else { return nil }
        let slack = frame.insetBy(dx: -StatusItemPlacement.tolerance, dy: -StatusItemPlacement.tolerance)
        if slack.contains(area) { return area }
        return area.offsetBy(dx: frame.origin.x, dy: frame.origin.y)
    }

    @MainActor
    init(_ screen: NSScreen) {
        self.init(
            frame: screen.frame,
            topLeft: screen.auxiliaryTopLeftArea, topRight: screen.auxiliaryTopRightArea)
    }

    @MainActor static var current: [ScreenGeometry] { NSScreen.screens.map(ScreenGeometry.init) }
}
