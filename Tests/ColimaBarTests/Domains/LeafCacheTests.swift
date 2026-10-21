import Foundation
import Security
import Testing

@testable import ColimaBar

@Suite struct LeafCacheTests {
    private let day: TimeInterval = 86400

    private func rig(
        capacity: Int = 256, mintLimit: Int = 4096, suffixes: [String] = ["localhost"]
    ) throws -> (cache: LeafCache, clock: TestClock, ca: LocalCA) {
        let clock = TestClock()
        let ca = try LocalCA.create(permitted: suffixes, now: clock.now)
        let cache = LeafCache(
            ca: ca, provider: PrivateIdentityProvider(), suffixes: suffixes, capacity: capacity,
            mintLimit: mintLimit, now: { clock.now })
        return (cache, clock, ca)
    }

    /// The common name of the certificate in an identity.
    private func name(_ identity: sec_identity_t?) -> String? {
        guard let identity, let ref = sec_identity_copy_ref(identity)?.takeRetainedValue() else { return nil }
        var cert: SecCertificate?
        guard SecIdentityCopyCertificate(ref, &cert) == errSecSuccess, let cert else { return nil }
        return SecCertificateCopySubjectSummary(cert) as String?
    }

    @Test func theMintNamePolicy() {
        let suffixes = ["localhost", "colima.internal"]
        let table: [(String?, String)] = [
            (nil, "localhost"),
            ("", "localhost"),
            ("web.shop.localhost", "web.shop.localhost"),
            ("WEB.Shop.LocalHost", "web.shop.localhost"),
            ("web.shop.localhost.", "web.shop.localhost"),
            ("localhost", "localhost"),
            ("api.colima.internal", "api.colima.internal"),
            ("www.example.com", "localhost"),
            ("evil.internal", "localhost"),
            ("notlocalhost", "localhost"),
            ("127.0.0.1", "localhost"),
            ("web.shop.localhost:8443", "web.shop.localhost"),
            ("bad name.localhost", "localhost"),
            ("[::1]", "localhost"),
        ]
        for (sni, expected) in table {
            #expect(LeafCache.mintName(sni: sni, suffixes: suffixes) == expected, "\(sni ?? "nil")")
        }
    }

    @Test func aNameIsMintedOnceAndThenServedFromTheCache() throws {
        let (cache, _, _) = try rig()
        for _ in 0..<4 { #expect(name(cache.identity(forSNI: "web.shop.localhost")) == "web.shop.localhost") }
        #expect(cache.mintedCount == 1)
        #expect(name(cache.identity(forSNI: "api.shop.localhost")) == "api.shop.localhost")
        #expect(cache.mintedCount == 2)
    }

    @Test func aForeignOrMissingNameGetsTheLocalhostLeaf() throws {
        let (cache, _, _) = try rig()
        #expect(name(cache.identity(forSNI: nil)) == "localhost")
        #expect(name(cache.identity(forSNI: "www.example.com")) == "localhost")
        #expect(name(cache.identity(forSNI: "10.0.0.1")) == "localhost")
        #expect(cache.mintedCount == 1)
    }

    @Test func aLeafWithLessThanADayLeftIsMadeAgain() throws {
        let (cache, clock, _) = try rig()
        _ = cache.identity(forSNI: "a.localhost")
        clock.advance(29 * day)
        _ = cache.identity(forSNI: "a.localhost")
        #expect(cache.mintedCount == 1)  // 1 day and 1 hour are left
        clock.advance(day)
        _ = cache.identity(forSNI: "a.localhost")
        #expect(cache.mintedCount == 2)
        _ = cache.identity(forSNI: "a.localhost")
        #expect(cache.mintedCount == 2)
    }

    @Test func theLeastRecentlyUsedLeafGoesFirst() throws {
        let (cache, _, _) = try rig(capacity: 2)
        _ = cache.identity(forSNI: "a.localhost")
        _ = cache.identity(forSNI: "b.localhost")
        _ = cache.identity(forSNI: "a.localhost")  // a is newer than b now
        _ = cache.identity(forSNI: "c.localhost")  // b goes
        #expect(cache.mintedCount == 3)
        _ = cache.identity(forSNI: "a.localhost")
        #expect(cache.mintedCount == 3)
        _ = cache.identity(forSNI: "b.localhost")
        #expect(cache.mintedCount == 4)
    }

    @Test func aCacheMintsNoMoreThanItsLimitAndServesLocalhostAfterwards() throws {
        let (cache, _, _) = try rig(mintLimit: 2)
        #expect(name(cache.identity(forSNI: "a.localhost")) == "a.localhost")
        #expect(name(cache.identity(forSNI: "b.localhost")) == "b.localhost")
        #expect(name(cache.identity(forSNI: "c.localhost")) == "localhost")
        #expect(cache.mintedCount == 3)
        #expect(name(cache.identity(forSNI: "d.localhost")) == "localhost")
        #expect(cache.mintedCount == 3)
    }

    @Test func oneIdentityServesAllTheNamesOfTheFallbackMode() throws {
        let (cache, _, _) = try rig()
        let names = ["web.shop.localhost", "api.shop.localhost", "localhost"]
        let one = cache.multiSANIdentity(names: names)
        #expect(one != nil)
        #expect(cache.multiSANIdentity(names: names.reversed()) != nil)
        #expect(cache.mintedCount == 1)
        _ = cache.multiSANIdentity(names: names + ["x.localhost"])
        #expect(cache.mintedCount == 2)
    }

    @Test func aResetDropsTheLeavesAndSignsWithTheNewCA() throws {
        let (cache, _, _) = try rig()
        _ = cache.identity(forSNI: "a.localhost")
        let next = try LocalCA.create(permitted: ["localhost"])
        cache.reset(ca: next, suffixes: ["localhost"])
        _ = cache.identity(forSNI: "a.localhost")
        #expect(cache.mintedCount == 2)
    }

    @Test func manyThreadsGetOneLeafForOneName() async throws {
        let (cache, _, _) = try rig()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    for _ in 0..<5 { _ = await onOwnThread { cache.identity(forSNI: "same.localhost") != nil } }
                }
            }
        }
        #expect(cache.mintedCount == 1)
    }
}
