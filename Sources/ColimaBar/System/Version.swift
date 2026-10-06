import Foundation

/// Dotted numeric versions ("0.3.0"). Build suffixes ("0.2.0-4-gabc-dirty")
/// and a leading "v" are ignored.
enum Version {
    static func strip(_ s: String) -> String { s.hasPrefix("v") ? String(s.dropFirst()) : s }

    static func parts(_ s: String) -> [Int]? {
        let core = strip(s).split(separator: "-").first.map(String.init) ?? ""
        let fields = core.split(separator: ".")
        let nums = fields.compactMap { Int($0) }
        // Every field must be a number.
        guard !nums.isEmpty, nums.count == fields.count else { return nil }
        return nums
    }

    /// True if `a` is a higher version than `b`. Unparseable versions (e.g. a
    /// "dev" build) never count as older, so they don't nag.
    static func isNewer(_ a: String, than b: String) -> Bool {
        guard let x = parts(a), let y = parts(b) else { return false }
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }
}
