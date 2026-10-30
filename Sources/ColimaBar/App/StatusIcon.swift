import AppKit

/// The symbols of the menu bar icon. The symbols differ in size (the hourglass
/// is narrower than the box, and the triangle is wider). Each one is drawn
/// centred on one canvas, so the icon keeps its size when the symbol changes.
@MainActor
enum StatusIcon: String, CaseIterable {
    case stopped = "shippingbox"
    case running = "shippingbox.fill"
    case unhealthy = "exclamationmark.triangle.fill"
    case busy = "hourglass"

    /// The widest symbol and the tallest one, in whole points with an even
    /// height. A fraction or an odd height would blur the glyphs on a 1x screen.
    private static let canvas: NSSize = {
        let sizes = allCases.compactMap { $0.symbol?.size }
        let height = ceil(sizes.map(\.height).max() ?? 0)
        return NSSize(
            width: ceil(sizes.map(\.width).max() ?? 0),
            height: height.truncatingRemainder(dividingBy: 2) == 0 ? height : height + 1)
    }()

    /// A template image of the symbol on the common canvas.
    var image: NSImage? {
        guard let glyph = symbol else { return nil }
        let size = glyph.size
        let img = NSImage(size: Self.canvas, flipped: false) { rect in
            // Whole offsets put the glyph on whole pixels.
            glyph.draw(
                in: NSRect(
                    x: floor((rect.width - size.width) / 2), y: floor((rect.height - size.height) / 2),
                    width: size.width, height: size.height))
            return true
        }
        img.isTemplate = true
        img.accessibilityDescription = "Colima"
        return img
    }

    private var symbol: NSImage? {
        NSImage(systemSymbolName: rawValue, accessibilityDescription: "Colima")
    }
}
