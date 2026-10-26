import Foundation
import Testing

@testable import ColimaBar

@Suite struct ImageUpdateCacheTests {
    private let d1 = "sha256:" + String(repeating: "1", count: 64)
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let nginx = "docker.io/library/nginx:latest"

    private func entry(_ digest: String? = nil, error: ImageUpdateStatus.Failure? = nil) -> ImageUpdateCache.Entry {
        .init(digest: digest ?? (error == nil ? d1 : nil), error: error, checkedAt: now)
    }

    @Test func theCacheRoundTrips() {
        var cache = ImageUpdateCache()
        cache.set([nginx: entry(), "ghcr.io/o/a:1": entry(error: .rateLimited)], profile: "work")
        cache.set(["docker.io/library/redis:7": entry()], profile: "default")
        let (back, problem) = ImageUpdateCache.decodeChecked(cache.json)
        #expect(back == cache && problem == nil)
        #expect(cache.json == back.json)
    }

    @Test func missingOrBrokenTextGivesAnEmptyCache() {
        #expect(ImageUpdateCache.decodeChecked(nil).cache == ImageUpdateCache())
        #expect(ImageUpdateCache.decodeChecked("").problem == nil)
        let broken = ImageUpdateCache.decodeChecked("{not json")
        #expect(broken.cache == ImageUpdateCache() && broken.problem != nil)
    }

    @Test func oneBadEntryKeepsTheOthers() {
        let text = """
            {"work":{
              "docker.io/library/nginx:latest":{"digest":"\(d1)","checkedAt":1800000000},
              "docker.io/library/bad:1":{"digest":"md5:1","checkedAt":1800000000},
              "docker.io/library/empty:1":{"checkedAt":1800000000},
              "docker.io/library/time:1":{"digest":"\(d1)","checkedAt":-5},
              "docker.io/library/kind:1":{"error":"nonsense","checkedAt":1800000000},
              "Not A Ref":{"digest":"\(d1)","checkedAt":1800000000},
              "nginx":{"digest":"\(d1)","checkedAt":1800000000}
            }}
            """
        let (cache, problem) = ImageUpdateCache.decodeChecked(text)
        #expect(cache.entries(of: "work").keys.sorted() == [nginx])
        #expect(problem == "6 invalid entries in the cache of image updates")
    }

    @Test func profilesThatAreGoneArePruned() {
        var cache = ImageUpdateCache()
        cache.set([nginx: entry()], profile: "a")
        cache.set([nginx: entry()], profile: "b")
        cache.set([nginx: entry()], profile: "c")
        let pruned = cache.pruned(keeping: ["a"], busy: ["c"])
        #expect(Set(pruned.profiles.keys) == ["a", "c"])
        // An empty list (colima list failed) removes nothing.
        #expect(cache.pruned(keeping: []) == cache)
    }

    @Test func entriesOfImagesThatNoContainerUsesAreTrimmed() {
        var cache = ImageUpdateCache()
        cache.set([nginx: entry(), "docker.io/library/redis:7": entry()], profile: "a")
        cache.set([nginx: entry()], profile: "b")
        let trimmed = cache.trimmed(profile: "a", keeping: [nginx])
        #expect(trimmed.entries(of: "a").keys.sorted() == [nginx])
        #expect(trimmed.entries(of: "b").count == 1)
        #expect(cache.trimmed(profile: "a", keeping: []).profiles["a"] == nil)
    }
}
