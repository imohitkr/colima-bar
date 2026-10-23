import Foundation
import Security
import Testing

@testable import ColimaBar

@Suite struct LeafCacheTests {
    private let day: TimeInterval = 86400

    private func rig(
        capacity: Int = 256, suffixes: [String] = ["localhost"],
        resolves: @escaping @Sendable (String) -> String? = { $0 }
    ) throws -> (cache: LeafCache, clock: TestClock, ca: LocalCA) {
        let clock = TestClock()
        let ca = try LocalCA.create(permitted: suffixes, now: clock.now)
        let cache = LeafCache(
            ca: ca, suffixes: suffixes, capacity: capacity,
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
        let (cache, _, _) = try rig(capacity: 8, resolves: { $0 })
        for i in 0..<40 { _ = cache.identity(forSNI: "n\(i).localhost") }
        #expect(cache.mintedCount == 40)
        #expect(cache.leafCount == 8)
        // A name that was dropped gets a new leaf at its next request.
        #expect(name(cache.identity(forSNI: "n0.localhost")) == "n0.localhost")
        #expect(cache.mintedCount == 41)
    }

    @Test func aLeafThatIsMadeAgainReplacesTheOldOne() throws {
        let (cache, clock, _) = try rig()
        _ = cache.identity(forSNI: "a.localhost")
        #expect(cache.leafCount == 1)
        clock.advance(30 * day)
        _ = cache.identity(forSNI: "a.localhost")
        #expect(cache.mintedCount == 2)
        #expect(cache.leafCount == 1)
    }

    @Test func aNewEpochMakesANewCertificateAndTheOldOnesGoAfterwards() throws {
        let (cache, _, _) = try rig()
        _ = cache.multiSANIdentity(names: ["a.localhost"], epoch: 1)
        _ = cache.multiSANIdentity(names: ["a.localhost", "b.localhost"], epoch: 1)
        _ = cache.identity(forSNI: "route.localhost")
        // The new certificate exists before the old ones are dropped.
        _ = cache.multiSANIdentity(names: ["a.localhost"], epoch: 2)
        #expect(cache.mintedCount == 4)
        #expect(cache.leafCount == 4)
        cache.dropMultiSAN(except: 2)
        #expect(cache.leafCount == 2)
        _ = cache.multiSANIdentity(names: ["a.localhost"], epoch: 2)
        _ = cache.identity(forSNI: "route.localhost")
        #expect(cache.mintedCount == 4)  // both stay
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

    @Test func theSuffixesDecideTheLeafOfACustomName() throws {
        #expect(LeafCache.mintName(sni: "a.dev.test", suffixes: ["localhost"], resolves: { $0 }) == "localhost")
        #expect(
            LeafCache.mintName(sni: "a.dev.test", suffixes: ["localhost", "dev.test"], resolves: { $0 })
                == "a.dev.test")
        let (cache, _, _) = try rig(suffixes: ["localhost", "dev.test"])
        #expect(cache.identity(forSNI: "a.dev.test") != nil)
        #expect(cache.mintedCount == 1)
        _ = cache.identity(forSNI: "a.dev.test")
        #expect(cache.mintedCount == 1)  // cached under its own name
    }

    @Test func aFailedMintReturnsNilAndStoresNothing() throws {
        // A CA whose key is a public key cannot sign.
        let real = try LocalCA.create(permitted: ["localhost"])
        let publicKey = try #require(SecKeyCopyPublicKey(real.key))
        let broken = LocalCA(
            certificate: real.certificate, der: real.der, key: publicKey, publicX963: real.publicX963,
            name: real.name, keyID: real.keyID, permitted: real.permitted)
        let cache = LeafCache(ca: broken, suffixes: ["localhost"], resolves: { $0 })
        #expect(cache.identity(forSNI: "a.localhost") == nil)
        #expect(cache.multiSANIdentity(names: ["a.localhost"]) == nil)
        #expect(cache.mintedCount == 0)
        #expect(cache.leafCount == 0)
    }

    @Test func aRouteUnderTheCustomSuffixGetsItsOwnLeaf() {
        let name = LeafCache.mintName(
            sni: "api.web.dev.test", suffixes: ["localhost", "dev.test"],
            resolves: { $0.hasSuffix("web.dev.test") ? "web.dev.test" : nil })
        #expect(name == "web.dev.test")
    }
}
