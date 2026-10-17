import Foundation

/// One tool that has another version than at the last good start.
struct VersionChange: Equatable, Sendable {
    enum Tool: String, Sendable {
        case colima = "Colima"
        case lima = "Lima"
        case macOS
    }

    enum Kind: Sendable {
        case patch, minor, major, downgrade
    }

    let tool: Tool
    let from: String
    let to: String
    let kind: Kind

    /// The kind of change, or nil if the versions are equal or one of them is
    /// not a version. Build suffixes do not count.
    static func kind(from old: String, to new: String) -> Kind? {
        guard let a = Version.parts(old), let b = Version.parts(new) else { return nil }
        let count = max(a.count, b.count, 3)
        func pad(_ x: [Int]) -> [Int] { x + Array(repeating: 0, count: count - x.count) }
        let (x, y) = (pad(a), pad(b))
        guard x != y else { return nil }
        if Version.isNewer(old, than: new) { return .downgrade }
        if y[0] != x[0] { return .major }
        if y[1] != x[1] { return .minor }
        return .patch
    }

    /// A minor or major bump of Colima or Lima, or any downgrade of them.
    /// A patch change and a macOS change are not risky.
    var isRisky: Bool {
        guard tool != .macOS else { return false }
        return kind != .patch
    }

    /// For example "Colima 0.10.3 → 0.11.0".
    var text: String { "\(tool.rawValue) \(from) → \(to)" }
}
