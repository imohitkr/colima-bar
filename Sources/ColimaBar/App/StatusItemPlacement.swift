import CoreGraphics

/// Checks that the status item and the popover can be seen. macOS keeps a
/// status item that has no room in the menu bar, for example under the
/// camera housing, as a window with a normal frame that no one sees. A
/// popover on it also has no visible anchor.
enum StatusItemPlacement {
    /// The tolerance in points for the edge of a free area.
    static let tolerance: CGFloat = 1

    /// True if the status item is on a screen and the user can see it: its
    /// frame is not empty, its middle is on a screen, its x range is inside
    /// that screen, and, on a screen with a camera housing, inside the free
    /// area on one side of it. Only x is compared, because the height of
    /// the menu bar changes.
    static func canAnchor(item: CGRect, screens: [ScreenGeometry]) -> Bool {
        guard !item.isEmpty,
            let screen = screens.first(where: { $0.frame.contains(CGPoint(x: item.midX, y: item.midY)) }),
            item.minX >= screen.frame.minX, item.maxX <= screen.frame.maxX
        else { return false }
        guard let left = screen.topLeft, let right = screen.topRight else { return true }
        return [left, right].contains {
            item.minX >= $0.minX - tolerance && item.maxX <= $0.maxX + tolerance
        }
    }

    /// True if at least half of the window is on one screen.
    static func isOnScreen(_ window: CGRect, screens: [ScreenGeometry]) -> Bool {
        guard !window.isEmpty else { return false }
        return screens.contains {
            let part = $0.frame.intersection(window)
            return !part.isNull && part.width * part.height * 2 >= window.width * window.height
        }
    }
}
