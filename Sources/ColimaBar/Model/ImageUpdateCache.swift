import Foundation

/// The last registry answer for each image reference of each profile, and
/// the Docker Hub budget of all profiles. It is stored as a JSON string in
/// the defaults, so the badges and the budget come back after a relaunch with
/// no registry call:
/// `{"profiles":{"work":{"docker.io/library/nginx:latest":{"digest":"sha256:…","checkedAt":1800000000}}},"hub":{"calls":[1800000000]}}`.
struct ImageUpdateCache: Equatable, Sendable {
    struct Entry: Codable, Equatable, Sendable {
        /// The digest that the registry gave at the last good check. A failed
        /// check keeps it, so the badge stays.
        var digest: String?
        /// Why the last check failed, or nil.
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

        /// An entry has a digest or an error, and a time. A digest must be well formed.
        var isValid: Bool {
            guard checkedAt.isFinite, checkedAt >= 0 else { return false }
            if let digest, !digest.hasPrefix("sha256:") { return false }
            return digest != nil || error != nil
        }
    }

    /// The Docker Hub calls of all profiles. The limit is for each address,
    /// not for each profile, so the budget is not part of the entries and a
    /// trim never touches it.
    struct HubBudget: Codable, Equatable, Sendable {
        /// Seconds since 1970 of each call in the last hour.
        var calls: [Double] = []
        /// Seconds since 1970 until which Docker Hub waits after a rate limit answer.
        var pausedUntil: Double?
    }

    /// Profile to normalized reference to entry.
    var profiles: [String: [String: Entry]] = [:]
    var hub = HubBudget()

    /// One entry that can fail to decode without the others.
    private struct Lossy: Decodable {
        let entry: Entry?
        init(from decoder: any Decoder) throws { entry = try? Entry(from: decoder) }
    }

    /// The entries of one profile. A profile that is not a map gives nil.
    private struct LossyProfile: Decodable {
        let refs: [String: Lossy]?
        init(from decoder: any Decoder) throws { refs = try? [String: Lossy](from: decoder) }
    }

    /// The budget, or nil if it is not valid.
    private struct LossyHub: Decodable {
        let hub: HubBudget?
        init(from decoder: any Decoder) throws { hub = try? HubBudget(from: decoder) }
    }

    private struct Stored: Decodable {
        let profiles: [String: LossyProfile]?
        let hub: LossyHub?
        let profilesPresent: Bool
        let hubPresent: Bool

        enum Key: String, CodingKey { case profiles, hub }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: Key.self)
            profilesPresent = c.contains(.profiles)
            hubPresent = c.contains(.hub)
            profiles = try? c.decodeIfPresent([String: LossyProfile].self, forKey: .profiles)
            hub = try? c.decodeIfPresent(LossyHub.self, forKey: .hub)
        }
    }

    /// Invalid or missing text gives an empty cache. A part that is not valid
    /// does not drop the others: one entry, one profile or the budget. `problem`
    /// says what was wrong, without the content.
    static func decodeChecked(_ text: String?) -> (cache: ImageUpdateCache, problem: String?) {
        guard let text, !text.isEmpty else { return (ImageUpdateCache(), nil) }
        guard let stored = try? JSONDecoder().decode(Stored.self, from: Data(text.utf8)) else {
            return (ImageUpdateCache(), "the cache of image updates is not valid")
        }
        var cache = ImageUpdateCache()
        var dropped = 0
        if let hub = stored.hub?.hub {
            cache.hub = hub
        } else if stored.hubPresent {
            dropped += 1
        }
        if stored.profiles == nil, stored.profilesPresent { dropped += 1 }
        for (profile, lossyProfile) in stored.profiles ?? [:] {
            guard let refs = lossyProfile.refs else {
                dropped += 1
                continue
            }
            for (ref, lossy) in refs {
                if let entry = lossy.entry, entry.isValid, ImageRef.parse(ref)?.normalized == ref {
                    cache.profiles[profile, default: [:]][ref] = entry
                } else {
                    dropped += 1
                }
            }
        }
        return (cache, dropped > 0 ? "\(dropped) invalid parts in the cache of image updates" : nil)
    }

    static func decode(_ text: String?) -> ImageUpdateCache { decodeChecked(text).cache }

    /// The JSON text, with sorted keys so equal caches give equal text.
    var json: String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        struct Out: Encodable {
            let profiles: [String: [String: Entry]]
            let hub: HubBudget
        }
        guard let data = try? enc.encode(Out(profiles: profiles, hub: hub)) else { return "{}" }
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
        var copy = self
        copy.profiles = profiles.filter { listed.contains($0.key) || busy.contains($0.key) }
        return copy
    }

    /// Only the entries of `refs` of `profile`. An entry of an image that no
    /// container uses any more has no use.
    func trimmed(profile: String, keeping refs: Set<String>) -> ImageUpdateCache {
        var copy = self
        copy.set(entries(of: profile).filter { refs.contains($0.key) }, profile: profile)
        return copy
    }
}
