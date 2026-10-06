import Foundation

/// Auto-stop timeout choices. `custom` is the picker tag for "Custom".
enum IdleMinutes {
    static let presets = [5, 15, 30, 60]
    static let custom = -1
    static let range = 1...1440

    /// Minutes typed in the custom field, or nil if not a whole number in range.
    static func parse(_ s: String) -> Int? {
        guard let n = Int(s.trimmingCharacters(in: .whitespaces)), range.contains(n) else { return nil }
        return n
    }

    /// The minutes to apply when the custom field is committed (Return or
    /// focus loss). Nil when the text is not valid or equals the current
    /// value, so a commit that changes nothing does not reset the idle timer.
    static func commit(_ s: String, current: Int) -> Int? {
        guard let n = parse(s), n != current else { return nil }
        return n
    }
}
