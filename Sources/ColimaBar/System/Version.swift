import Foundation

/// Dotted numeric versions ("0.3.0"). Build suffixes ("0.2.0-4-gabc-dirty")
/// and a leading "v" are ignored.
enum Version {
    static func strip(_ s: String) -> String { s.hasPrefix("v") ? String(s.dropFirst()) : s }

    static func parts(_ s: String) -> [Int]? {
        let core = strip(s).split(separator: "-").first.map(String.init) ?? ""
        let nums = core.split(separator: ".").map { Int($0) }
        guard !nums.isEmpty, nums.allSatisfy({ $0 != nil }) else { return nil }
        return nums.map { $0! }
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
