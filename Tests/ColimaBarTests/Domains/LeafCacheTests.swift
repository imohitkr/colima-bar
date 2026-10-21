import Foundation
import Security
import Testing

@testable import ColimaBar

@Suite struct LeafCacheTests {
    private let day: TimeInterval = 86400

    private func rig(
        capacity: Int = 256, suffixes: [String] = ["localhost"], provider: TLSIdentityProvider? = nil,
        resolves: @escaping @Sendable (String) -> String? = { $0 }
    ) throws -> (cache: LeafCache, clock: TestClock, ca: LocalCA) {
        let clock = TestClock()
        let ca = try LocalCA.create(permitted: suffixes, now: clock.now)
        let cache = LeafCache(
            ca: ca, provider: provider ?? PrivateIdentityProvider(), suffixes: suffixes, capacity: capacity,
            resolves: resolves, now: { clock.now })
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
            ("unrouted.localhost", "localhost"),
            ("a.unrouted.localhost", "localhost"),
            ("colimabar-selftest.localhost", "colimabar-selftest.localhost"),
            ("colimabar-selftest.colima.internal", "colimabar-selftest.colima.internal"),
            ("evillocalhost", "localhost"),
            ("localhost.evil.com", "localhost"),
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
            let name = LeafCache.mintName(sni: sni, suffixes: suffixes) { $0.contains("unrouted") ? nil : $0 }
            #expect(name == expected, "\(sni ?? "nil")")
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

    @Test func aNameWithoutARouteGetsTheLocalhostLeafAndIsNeverMinted() throws {
        let (cache, _, _) = try rig(resolves: { $0 == "web.localhost" ? $0 : nil })
        #expect(name(cache.identity(forSNI: "random.localhost")) == "localhost")
        #expect(cache.mintedCount == 1)  // the localhost leaf
        for i in 0..<500 { #expect(name(cache.identity(forSNI: "flood-\(i).localhost")) == "localhost") }
        #expect(cache.mintedCount == 1)
        // The real name still gets its own leaf, and keeps it.
        #expect(name(cache.identity(forSNI: "web.localhost")) == "web.localhost")
        #expect(cache.mintedCount == 2)
        #expect(name(cache.identity(forSNI: "web.localhost")) == "web.localhost")
        #expect(cache.mintedCount == 2)
    }

    @Test func theSelfTestNameIsMintedForEachSuffix() throws {
        let suffixes = ["localhost", "colima.internal"]
        let (cache, _, _) = try rig(suffixes: suffixes, resolves: { _ in nil })
        #expect(name(cache.identity(forSNI: "colimabar-selftest.localhost")) == "colimabar-selftest.localhost")
        #expect(
            name(cache.identity(forSNI: "colimabar-selftest.colima.internal"))
                == "colimabar-selftest.colima.internal")
        #expect(cache.mintedCount == 2)
    }

    @Test func everySubdomainOfARouteSharesTheLeafOfTheRoute() throws {
        let (cache, _, _) = try rig(resolves: { $0.hasSuffix("web.localhost") ? "web.localhost" : nil })
        for i in 0..<300 { #expect(name(cache.identity(forSNI: "n\(i).web.localhost")) == "web.localhost") }
        #expect(name(cache.identity(forSNI: "web.localhost")) == "web.localhost")
        #expect(cache.mintedCount == 1)
        // Another route has its own leaf, and a name outside the routes gets the fixed one.
        #expect(name(cache.identity(forSNI: "other.localhost")) == "localhost")
        #expect(cache.mintedCount == 2)
    }

    @Test func theLeafOfARouteNamesTheRouteAndItsSubdomains() throws {
        let (cache, _, _) = try rig(resolves: { $0.hasSuffix("web.localhost") ? "web.localhost" : nil })
        let identity = try #require(cache.identity(forSNI: "x.web.localhost"))
        let ref = try #require(sec_identity_copy_ref(identity)?.takeRetainedValue())
        var cert: SecCertificate?
        #expect(SecIdentityCopyCertificate(ref, &cert) == errSecSuccess)
        let der = [UInt8](SecCertificateCopyData(try #require(cert)) as Data)
        let text = String(decoding: der, as: UTF8.self)
        #expect(text.contains("*.web.localhost"))
        #expect(!text.contains("x.web.localhost"))
    }

    @Test func theNumberOfLeavesStaysInsideTheCapacity() throws {
        let provider = FakeDomainTLS.RecordingProvider()
        let (cache, _, _) = try rig(capacity: 8, provider: provider, resolves: { $0 })
        for i in 0..<40 { _ = cache.identity(forSNI: "n\(i).localhost") }
        #expect(cache.mintedCount == 40)
        #expect(provider.discardCount == 32)
        // A name that was dropped gets a new leaf at its next request.
        #expect(name(cache.identity(forSNI: "n0.localhost")) == "n0.localhost")
        #expect(cache.mintedCount == 41)
    }

    @Test func theKeychainOfALeafGoesWhenTheCacheDropsTheLeaf() throws {
        let temp = try TempFolder()
        let provider = try #require(FileKeychainIdentityProvider(cacheDir: temp.path))
        defer { provider.removeAll() }
        let (cache, _, _) = try rig(capacity: 2, provider: provider)
        for host in ["a", "b", "c", "d", "e"] { _ = cache.identity(forSNI: "\(host).localhost") }
        // Two leaves stay: each has a key and a certificate.
        #expect(provider.itemCount == 4)
    }

    @Test func aLeafThatIsMadeAgainReplacesTheOldOneInTheKeychain() throws {
        let temp = try TempFolder()
        let provider = try #require(FileKeychainIdentityProvider(cacheDir: temp.path))
        defer { provider.removeAll() }
        let (cache, clock, _) = try rig(provider: provider)
        _ = cache.identity(forSNI: "a.localhost")
        #expect(provider.itemCount == 2)
        clock.advance(30 * day)
        _ = cache.identity(forSNI: "a.localhost")
        #expect(cache.mintedCount == 2)
        #expect(provider.itemCount == 2)
    }

    @Test func theFallbackCertificateIsMadeAgainAfterItIsDropped() throws {
        let (cache, _, _) = try rig()
        _ = cache.multiSANIdentity(names: ["a.localhost"])
        _ = cache.multiSANIdentity(names: ["a.localhost"])
        #expect(cache.mintedCount == 1)
        _ = cache.identity(forSNI: "b.localhost")
        cache.dropMultiSAN(except: nil)
        _ = cache.multiSANIdentity(names: ["a.localhost"])
        #expect(cache.mintedCount == 3)
        _ = cache.identity(forSNI: "b.localhost")
        #expect(cache.mintedCount == 3)  // the leaf of a name stays
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

    @Test func aNewEpochMakesANewCertificateAndTheOldOnesGoAfterwards() throws {
        let provider = FakeDomainTLS.RecordingProvider()
        let (cache, _, _) = try rig(provider: provider)
        _ = cache.multiSANIdentity(names: ["a.localhost"], epoch: 1)
        _ = cache.multiSANIdentity(names: ["a.localhost", "b.localhost"], epoch: 1)
        _ = cache.identity(forSNI: "route.localhost")
        // The new certificate exists before the old ones are dropped.
        _ = cache.multiSANIdentity(names: ["a.localhost"], epoch: 2)
        #expect(cache.mintedCount == 4)
        #expect(provider.discardCount == 0)
        cache.dropMultiSAN(except: 2)
        #expect(provider.discardCount == 2)
        _ = cache.multiSANIdentity(names: ["a.localhost"], epoch: 2)
        _ = cache.identity(forSNI: "route.localhost")
        #expect(cache.mintedCount == 4)  // both stay
    }

    @Test func discardAllDeletesEveryLeaf() throws {
        let provider = FakeDomainTLS.RecordingProvider()
        let (cache, _, _) = try rig(provider: provider)
        _ = cache.identity(forSNI: "a.localhost")
        _ = cache.multiSANIdentity(names: ["a.localhost"], epoch: 1)
        cache.discardAll()
        #expect(provider.discardCount == 2)
        _ = cache.identity(forSNI: "a.localhost")
        #expect(cache.mintedCount == 3)
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

    @Test func resetUsesTheNewSuffixes() throws {
        let (cache, _, _) = try rig()
        #expect(LeafCache.mintName(sni: "a.dev.test", suffixes: ["localhost"], resolves: { _ in true }) == "localhost")
        #expect(
            LeafCache.mintName(sni: "a.dev.test", suffixes: ["localhost", "dev.test"], resolves: { _ in true })
                == "a.dev.test")
        _ = cache.identity(forSNI: "a.dev.test")  // before: the localhost leaf
        let before = cache.mintedCount
        let next = try LocalCA.create(permitted: ["localhost", "dev.test"])
        cache.reset(ca: next, suffixes: ["localhost", "dev.test"])
        #expect(cache.identity(forSNI: "a.dev.test") != nil)
        #expect(cache.mintedCount == before + 1)
        _ = cache.identity(forSNI: "a.dev.test")
        #expect(cache.mintedCount == before + 1)  // cached under its own name
    }
}
