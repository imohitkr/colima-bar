/// The text of a combo as the keyboard layout shows it.
extension KeyCombo {
    /// The symbols with the key name of the current layout.
    @MainActor var display: String { symbols(keyName: KeyLayout.name(for: keyCode)) }
}
