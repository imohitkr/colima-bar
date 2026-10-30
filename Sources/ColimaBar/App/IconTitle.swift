/// The text next to the menu bar icon. The text keeps one width while the
/// count changes, so the icon and the dashboard anchored to it do not move.
enum IconTitle {
    /// A figure space has the width of a digit in the monospaced digit font.
    private static let figureSpace = "\u{2007}"

    /// The title for a running count: a space, then the count padded on the
    /// left with figure spaces to `digits` digits. A count of 0 has no title.
    static func format(count: Int, digits: Int) -> String {
        guard count > 0 else { return "" }
        let number = String(count)
        let padding = String(repeating: figureSpace, count: max(0, digits - number.count))
        return " " + padding + number
    }
}
