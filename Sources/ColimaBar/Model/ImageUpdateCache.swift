import Foundation

/// The last registry answer for each image reference of each profile. It is
/// stored as a JSON string in the defaults, so the badges come back after a
/// relaunch with no registry call:
/// `{"work":{"docker.io/library/nginx:latest":{"digest":"sha256:…","checkedAt":1800000000}}}`.
struct ImageUpdateCache: Equatable, Sendable {
    struct Entry: Codable, Equatable, Sendable {
        /// The digest that the registry gave, or nil when the check failed.
        var digest: String?
        var error: ImageUpdateStatus.Failure?
        /// Seconds since 1970.
        var checkedAt: Double
        /// A pull of this digest ended. The registry digest can stay out of
        /// `RepoDigests` after it, so this keeps the badge off.
        var pulled: Bool?

        var date: Date { Date(timeIntervalSince1970: checkedAt) }

        init(digest: String? = nil, error: ImageUpdateStatus.Failure? = nil, checkedAt: Date, pulled: Bool? = nil) {
            self.digest = digest
            self.error = error
            self.checkedAt = checkedAt.timeIntervalSince1970
            self.pulled = pulled
        }

        /// An entry has a digest or an error, and a time.
        var isValid: Bool {
            guard checkedAt.isFinite, checkedAt >= 0 else { return false }
            if let digest { return digest.hasPrefix("sha256:") }
            return error != nil
        }
    }

    /// Profile to normalized reference to entry.
    var profiles: [String: [String: Entry]] = [:]

    /// One entry that can fail to decode without the others.
    private struct Lossy: Decodable {
        let entry: Entry?
        init(from decoder: any Decoder) throws { entry = try? Entry(from: decoder) }
    }

    /// Invalid or missing text gives an empty cache. One invalid entry does
    /// not drop the others. `problem` says what was wrong, without the content.
    static func decodeChecked(_ text: String?) -> (cache: ImageUpdateCache, problem: String?) {
        guard let text, !text.isEmpty else { return (ImageUpdateCache(), nil) }
        guard let raw = try? JSONDecoder().decode([String: [String: Lossy]].self, from: Data(text.utf8)) else {
            return (ImageUpdateCache(), "the cache of image updates is not valid")
        }
        var cache = ImageUpdateCache()
        var dropped = 0
        for (profile, refs) in raw {
            for (ref, lossy) in refs {
                if let entry = lossy.entry, entry.isValid, ImageRef.parse(ref)?.normalized == ref {
                    cache.profiles[profile, default: [:]][ref] = entry
                } else {
                    dropped += 1
                }
            }
        }
        return (cache, dropped > 0 ? "\(dropped) invalid entries in the cache of image updates" : nil)
    }

    static func decode(_ text: String?) -> ImageUpdateCache { decodeChecked(text).cache }

    /// The JSON text, with sorted keys so equal caches give equal text.
    var json: String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        guard let data = try? enc.encode(profiles) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    func entries(of profile: String) -> [String: Entry] { profiles[profile] ?? [:] }

    mutating func set(_ entries: [String: Entry], profile: String) {
        if entries.isEmpty {
            profiles[profile] = nil
        } else {
            profiles[profile] = entries
        }
    }

    /// Only the entries of the listed profiles, and of the profiles with a
    /// busy marker: a disk shrink deletes a profile for a short time. An empty
    /// list (`colima list` failed) removes nothing.
    func pruned(keeping listed: Set<String>, busy: Set<String> = []) -> ImageUpdateCache {
        guard !listed.isEmpty else { return self }
        return ImageUpdateCache(profiles: profiles.filter { listed.contains($0.key) || busy.contains($0.key) })
    }

    /// Only the entries of `refs` of `profile`. An entry of an image that no
    /// container uses any more has no use.
    func trimmed(profile: String, keeping refs: Set<String>) -> ImageUpdateCache {
        var copy = self
        copy.set(entries(of: profile).filter { refs.contains($0.key) }, profile: profile)
        return copy
    }
}
