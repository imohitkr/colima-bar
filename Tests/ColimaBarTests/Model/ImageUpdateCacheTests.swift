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
            {"profiles":{"work":{
              "docker.io/library/nginx:latest":{"digest":"\(d1)","checkedAt":1800000000},
              "docker.io/library/bad:1":{"digest":"md5:1","checkedAt":1800000000},
              "docker.io/library/empty:1":{"checkedAt":1800000000},
              "docker.io/library/time:1":{"digest":"\(d1)","checkedAt":-5},
              "docker.io/library/kind:1":{"error":"nonsense","checkedAt":1800000000},
              "Not A Ref":{"digest":"\(d1)","checkedAt":1800000000},
              "nginx":{"digest":"\(d1)","checkedAt":1800000000}
            }}}
            """
        let (cache, problem) = ImageUpdateCache.decodeChecked(text)
        #expect(cache.entries(of: "work").keys.sorted() == [nginx])
        #expect(problem == "6 invalid parts in the cache of image updates")
    }

    @Test func aBadBudgetKeepsTheProfilesAndABadProfileKeepsTheOthers() {
        let entry = #"{"digest":"\#(d1)","checkedAt":1800000000}"#
        let badHub = ImageUpdateCache.decodeChecked(
            #"{"profiles":{"a":{"\#(nginx)":\#(entry)}},"hub":{"calls":"x"}}"#)
        #expect(badHub.cache.entries(of: "a").keys.sorted() == [nginx])
        #expect(badHub.cache.hub == ImageUpdateCache.HubBudget())
        #expect(badHub.problem == "1 invalid parts in the cache of image updates")
        let badProfile = ImageUpdateCache.decodeChecked(
            #"{"profiles":{"a":{"\#(nginx)":\#(entry)},"b":[1]},"hub":{"calls":[1800000000]}}"#)
        #expect(badProfile.cache.entries(of: "a").keys.sorted() == [nginx])
        #expect(badProfile.cache.profiles["b"] == nil)
        #expect(badProfile.cache.hub.calls == [1_800_000_000])
        #expect(badProfile.problem == "1 invalid parts in the cache of image updates")
    }

    @Test func theDockerHubBudgetRoundTripsAndSurvivesPruningAndTrimming() {
        var cache = ImageUpdateCache()
        cache.set([nginx: entry()], profile: "a")
        cache.hub = .init(calls: [1_799_999_000, 1_799_999_500], pausedUntil: 1_800_020_000)
        #expect(ImageUpdateCache.decode(cache.json) == cache)
        #expect(cache.pruned(keeping: ["b"]).hub == cache.hub)
        #expect(cache.pruned(keeping: ["b"]).profiles.isEmpty)
        #expect(cache.trimmed(profile: "a", keeping: []).hub == cache.hub)
    }

    @Test func aFailedCheckCanKeepTheLastDigest() {
        let kept = ImageUpdateCache.Entry(digest: d1, error: .unreachable, checkedAt: now, pulled: true)
        #expect(kept.isValid)
        #expect(
            ImageUpdateCache.decode(
                #"{"profiles":{"a":{"\#(nginx)":{"digest":"md5:1","error":"other","checkedAt":1}}}}"#
            ).profiles.isEmpty)
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
