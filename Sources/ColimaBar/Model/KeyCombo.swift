import AppKit

/// A keyboard shortcut: one key and a set of modifiers. It is a pure value.
/// The key code and the modifier mask use the Carbon values, so `HotKey` can
/// pass them on without a conversion.
///
/// The stored form is one string, the spec, for example
/// `control+option+command+C`. The modifiers come in the order control,
/// option, shift, command, then the key.
struct KeyCombo: Equatable, Hashable, Sendable {
    let keyCode: UInt32
    /// The Carbon modifier mask (`cmdKey` and the others).
    let modifiers: UInt32

    // The Carbon modifier bits. They are the same as `cmdKey`, `shiftKey`,
    // `optionKey` and `controlKey` in HIToolbox.
    static let command: UInt32 = 0x100
    static let shift: UInt32 = 0x200
    static let option: UInt32 = 0x800
    static let control: UInt32 = 0x1000
    /// All four modifier bits. A symbolic hot key mask uses the same bits.
    static let modifierMask: UInt32 = command | shift | option | control

    /// Why ColimaBar cannot use a shortcut. Each case has a text for the user.
    enum Problem: Equatable, Sendable {
        case unsupportedKey
        case tooFewModifiers(functionKey: Bool)
        /// macOS uses the shortcut.
        case system
        /// Another app holds the shortcut.
        case inUse
        /// macOS refused the shortcut with this status.
        case failed(Int32)

        var message: String {
            switch self {
            case .unsupportedKey:
                "ColimaBar cannot use this key. Use a letter, a digit, a function key or Space."
            case .tooFewModifiers(let functionKey):
                functionKey
                    ? "Add ⌘, ⌃ or ⌥."
                    : "Use two or more of ⌘, ⌃ and ⌥ with this key, for example ⌃⌥⌘C."
            case .system:
                "macOS uses this shortcut. Record a different one, or turn it off in System Settings > Keyboard > Keyboard Shortcuts."
            case .inUse:
                "Another app uses this shortcut. Record a different one."
            case .failed(let status):
                "macOS refused this shortcut (error \(status)). Record a different one."
            }
        }
    }

    init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers & Self.modifierMask
    }

    /// The combo of a key event. Caps Lock, Fn and the keypad flag do not count.
    init(keyCode: UInt16, flags: NSEvent.ModifierFlags) {
        var mask: UInt32 = 0
        if flags.contains(.command) { mask |= Self.command }
        if flags.contains(.option) { mask |= Self.option }
        if flags.contains(.control) { mask |= Self.control }
        if flags.contains(.shift) { mask |= Self.shift }
        self.init(keyCode: UInt32(keyCode), modifiers: mask)
    }

    // MARK: - Keys

    /// A key that ColimaBar supports.
    private struct Key {
        let code: UInt32
        /// The name in the spec.
        let name: String
        /// The text that a screen reader says.
        let spoken: String
        /// The symbol for a US keyboard. A letter, digit or sign key shows
        /// the name from the keyboard layout instead.
        let symbol: String
        /// A key whose name comes from the keyboard layout.
        let printable: Bool
    }

    private static let keys: [Key] = {
        var list: [Key] = []
        func printable(_ code: UInt32, _ name: String, _ spoken: String? = nil, symbol: String? = nil) {
            list.append(Key(code: code, name: name, spoken: spoken ?? name, symbol: symbol ?? name, printable: true))
        }
        func other(_ code: UInt32, _ name: String, _ spoken: String, _ symbol: String) {
            list.append(Key(code: code, name: name, spoken: spoken, symbol: symbol, printable: false))
        }
        let letters: [(UInt32, String)] = [
            (0, "A"), (11, "B"), (8, "C"), (2, "D"), (14, "E"), (3, "F"), (5, "G"), (4, "H"), (34, "I"),
            (38, "J"), (40, "K"), (37, "L"), (46, "M"), (45, "N"), (31, "O"), (35, "P"), (12, "Q"),
            (15, "R"), (1, "S"), (17, "T"), (32, "U"), (9, "V"), (13, "W"), (7, "X"), (16, "Y"), (6, "Z"),
        ]
        for (code, name) in letters { printable(code, name) }
        let digits: [(UInt32, String)] = [
            (29, "0"), (18, "1"), (19, "2"), (20, "3"), (21, "4"), (23, "5"), (22, "6"), (26, "7"),
            (28, "8"), (25, "9"),
        ]
        for (code, name) in digits { printable(code, name) }
        printable(27, "minus", "Minus", symbol: "-")
        printable(24, "equal", "Equals", symbol: "=")
        printable(33, "leftbracket", "Left Bracket", symbol: "[")
        printable(30, "rightbracket", "Right Bracket", symbol: "]")
        printable(42, "backslash", "Backslash", symbol: "\\")
        printable(41, "semicolon", "Semicolon", symbol: ";")
        printable(39, "quote", "Quote", symbol: "'")
        printable(43, "comma", "Comma", symbol: ",")
        printable(47, "period", "Period", symbol: ".")
        printable(44, "slash", "Slash", symbol: "/")
        printable(50, "grave", "Grave Accent", symbol: "`")
        other(49, "space", "Space", "Space")
        other(36, "return", "Return", "↩")
        other(48, "tab", "Tab", "⇥")
        other(51, "delete", "Delete", "⌫")
        other(117, "forwarddelete", "Forward Delete", "⌦")
        other(115, "home", "Home", "↖")
        other(119, "end", "End", "↘")
        other(116, "pageup", "Page Up", "⇞")
        other(121, "pagedown", "Page Down", "⇟")
        other(123, "left", "Left Arrow", "←")
        other(124, "right", "Right Arrow", "→")
        other(126, "up", "Up Arrow", "↑")
        other(125, "down", "Down Arrow", "↓")
        let function: [(UInt32, Int)] = [
            (122, 1), (120, 2), (99, 3), (118, 4), (96, 5), (97, 6), (98, 7), (100, 8), (101, 9), (109, 10),
            (103, 11), (111, 12), (105, 13), (107, 14), (113, 15), (106, 16), (64, 17), (79, 18), (80, 19),
            (90, 20),
        ]
        for (code, n) in function { other(code, "F\(n)", "F\(n)", "F\(n)") }
        return list
    }()

    private static let byCode: [UInt32: Key] = Dictionary(uniqueKeysWithValues: keys.map { ($0.code, $0) })
    private static let byName: [String: Key] = Dictionary(uniqueKeysWithValues: keys.map { ($0.name.lowercased(), $0) })

    /// All key codes that ColimaBar supports.
    static var supportedKeyCodes: [UInt32] { keys.map(\.code) }

    private var key: Key? { Self.byCode[keyCode] }

    var isFunctionKey: Bool {
        guard let name = key?.name else { return false }
        return name.hasPrefix("F") && name.count > 1
    }

    // MARK: - Spec

    private static let modifierNames: [(name: String, bit: UInt32)] = [
        ("control", control), ("option", option), ("shift", shift), ("command", command),
    ]

    /// The canonical string, for example `control+option+command+C`.
    /// An unsupported key gives the key code as a number.
    var spec: String {
        var parts = Self.modifierNames.filter { modifiers & $0.bit != 0 }.map(\.name)
        parts.append(key?.name ?? String(keyCode))
        return parts.joined(separator: "+")
    }

    /// Reads a spec. The words are not case sensitive. It needs exactly one
    /// key, and each modifier at most once. It does not check the rules for
    /// a usable shortcut: see `problem`.
    init?(spec: String) {
        var mask: UInt32 = 0
        var found: Key?
        for raw in spec.split(separator: "+", omittingEmptySubsequences: false) {
            let word = raw.lowercased()
            if let m = Self.modifierNames.first(where: { $0.name == word }) {
                guard mask & m.bit == 0 else { return nil }
                mask |= m.bit
            } else if let k = Self.byName[word], found == nil {
                found = k
            } else {
                return nil
            }
        }
        guard let found else { return nil }
        self.init(keyCode: found.code, modifiers: mask)
    }

    // MARK: - Rules

    /// The first rule that this combo breaks, or nil. It needs two or more
    /// of ⌘ ⌃ ⌥, or one of them with a function key. ⇧ does not count.
    var problem: Problem? {
        guard key != nil else { return .unsupportedKey }
        let count = [Self.command, Self.control, Self.option].filter { modifiers & $0 != 0 }.count
        if count >= 2 || (count == 1 && isFunctionKey) { return nil }
        return .tooFewModifiers(functionKey: isFunctionKey)
    }

    /// True if an enabled symbolic hot key of macOS has this key and these
    /// modifiers. `entries` is the list from `CopySymbolicHotKeys`.
    func isReserved(in entries: [[String: Any]]) -> Bool {
        func number(_ value: Any?) -> Int? { (value as? NSNumber)?.intValue }
        return entries.contains { entry in
            guard number(entry["kHISymbolicHotKeyEnabled"]) == 1,
                let code = number(entry["kHISymbolicHotKeyCode"]),
                let mods = number(entry["kHISymbolicHotKeyModifiers"])
            else { return false }
            return UInt32(truncatingIfNeeded: code) == keyCode
                && UInt32(truncatingIfNeeded: mods) & Self.modifierMask == modifiers & Self.modifierMask
        }
    }

    // MARK: - Text

    private var modifierSymbols: String {
        var text = ""
        if modifiers & Self.control != 0 { text += "⌃" }
        if modifiers & Self.option != 0 { text += "⌥" }
        if modifiers & Self.shift != 0 { text += "⇧" }
        if modifiers & Self.command != 0 { text += "⌘" }
        return text
    }

    /// The shortcut as symbols, for example `⌃⌥⌘C`. `keyName` is the name of
    /// the key in the keyboard layout (see `KeyLayout`). A key without a
    /// layout name shows its US keyboard name.
    func symbols(keyName: String?) -> String {
        guard let key else { return modifierSymbols + "?" }
        let name = key.printable ? (keyName.map { $0.uppercased() } ?? key.symbol) : key.symbol
        return modifierSymbols + name
    }

    /// The shortcut as words for a screen reader, for example
    /// `Control Option Command C`.
    var spoken: String {
        var words: [String] = []
        if modifiers & Self.control != 0 { words.append("Control") }
        if modifiers & Self.option != 0 { words.append("Option") }
        if modifiers & Self.shift != 0 { words.append("Shift") }
        if modifiers & Self.command != 0 { words.append("Command") }
        words.append(key?.spoken ?? "Unknown key")
        return words.joined(separator: " ")
    }
}
