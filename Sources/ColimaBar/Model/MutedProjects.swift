import Foundation

/// The Compose projects whose banners are off. An entry is
/// `ColimaModel.composeKey(profile:name:)`: the same project name can exist
/// in two profiles.
enum MutedProjects {
    static let maxCount = 200
    private static let maxKeyLength = 200

    /// The stored list, without junk. Defaults can hold anything.
    static func decode(_ raw: [String]?) -> Set<String> {
        var out = Set<String>()
        for key in raw ?? [] where isValid(key) {
            out.insert(key)
            if out.count == maxCount { break }
        }
        return out
    }

    /// Sorted, so the stored list does not change without a reason.
    static func encode(_ muted: Set<String>) -> [String] { muted.sorted() }

    /// Adds or removes `key`. It refuses an add at the cap, never a removal.
    static func toggled(_ muted: Set<String>, key: String, muted on: Bool) -> Set<String> {
        var out = muted
        if on {
            guard isValid(key), out.count < maxCount || out.contains(key) else { return muted }
            out.insert(key)
        } else {
            out.remove(key)
        }
        return out
    }

    /// `profile/project`: a slash with text on both sides.
    private static func isValid(_ key: String) -> Bool {
        guard key.count <= maxKeyLength, let slash = key.firstIndex(of: "/") else { return false }
        return slash != key.startIndex && key.index(after: slash) != key.endIndex
    }
}
