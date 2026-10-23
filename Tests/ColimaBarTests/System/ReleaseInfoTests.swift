import Foundation
import Testing

@testable import ColimaBar

@Suite struct ReleaseInfoTests {
    private let digest = "36648ccc9586aba8e5e398f0e26748a419fd4b80c43643bdf0ba609576dc8bfe"

    /// The shape of the answer of releases/latest for v0.8.0 (shortened).
    private func json(
        tag: String = "v0.8.0", draft: Bool = false, prerelease: Bool = false, immutable: Bool? = true,
        assets: String? = nil, body: String? = nil
    ) -> Data {
        let zip =
            assets
                ?? """
                {"name":"ColimaBar.dmg","size":1511194,"state":"uploaded",
                 "digest":"sha256:f1186375de78c2f07552df38d6a32ca62a325cecfc96e177684551a786cf22c9",
                 "browser_download_url":"https://github.com/imohitkr/colima-bar/releases/download/\(tag)/ColimaBar.dmg"},
                {"name":"ColimaBar.zip","size":1450000,"state":"uploaded","digest":"sha256:\(digest)",
                 "browser_download_url":"https://evil.example/ColimaBar.zip"}
                """
        let bodyField = body.map { ",\"body\":\(String(decoding: try! JSONEncoder().encode($0), as: UTF8.self))" } ?? ""
        let imm = immutable.map { ",\"immutable\":\($0)" } ?? ""
        return Data(
            """
            {"url":"https://api.github.com/repos/imohitkr/colima-bar/releases/1","html_url":"https://evil.example/x",
             "tag_name":"\(tag)","draft":\(draft),"prerelease":\(prerelease)\(imm)\(bodyField),"assets":[\(zip)]}
            """.utf8)
    }

    @Test func readsAnImmutableRelease() throws {
        let r = try #require(ReleaseInfo.parse(json()))
        #expect(r.version == "0.8.0")
        #expect(r.tag == "v0.8.0")
        #expect(r.zip == ReleaseInfo.Asset(size: 1_450_000, sha256: digest))
        // The page comes from the tag, not from html_url.
        #expect(r.page.absoluteString == "https://github.com/imohitkr/colima-bar/releases/tag/v0.8.0")
    }

    @Test func readsTheMinimumMacOSFromTheBody() throws {
        #expect(try #require(ReleaseInfo.parse(json())).minimumMacOS == nil)
        #expect(try #require(ReleaseInfo.parse(json(body: "Notes only"))).minimumMacOS == nil)
        let r = try #require(ReleaseInfo.parse(json(body: "Requires macOS 15.0 or later.\n\n## What's Changed")))
        #expect(r.minimumMacOS == "15.0")
    }

    @Test func rejectsDraftsAndPrereleases() {
        #expect(ReleaseInfo.parse(json(draft: true)) == nil)
        #expect(ReleaseInfo.parse(json(prerelease: true)) == nil)
    }

    @Test func rejectsDataThatIsNotARelease() {
        #expect(ReleaseInfo.parse(Data("[]".utf8)) == nil)
        #expect(ReleaseInfo.parse(Data("{}".utf8)) == nil)
        #expect(ReleaseInfo.parse(Data("not json".utf8)) == nil)
    }

    @Test func aMutableReleaseHasNoZip() throws {
        #expect(try #require(ReleaseInfo.parse(json(immutable: false))).zip == nil)
        #expect(try #require(ReleaseInfo.parse(json(immutable: nil))).zip == nil)
    }

    @Test func onlyTheExactAssetNameCounts() throws {
        for name in ["ColimaBar.zip.sig", "colimabar.zip", "ColimaBar-0.8.0.zip", "../ColimaBar.zip"] {
            let assets = "{\"name\":\"\(name)\",\"size\":10,\"digest\":\"sha256:\(digest)\"}"
            #expect(try #require(ReleaseInfo.parse(json(assets: assets))).zip == nil, "\(name)")
        }
    }

    @Test func twoAssetsWithTheNameGiveNoZip() throws {
        let one = "{\"name\":\"ColimaBar.zip\",\"size\":10,\"digest\":\"sha256:\(digest)\"}"
        #expect(try #require(ReleaseInfo.parse(json(assets: "\(one),\(one)"))).zip == nil)
    }

    @Test func aBadDigestGivesNoZip() throws {
        for d in ["sha256:abc", "md5:\(digest)", digest, "sha256:\(digest)00"] {
            let assets = "{\"name\":\"ColimaBar.zip\",\"size\":10,\"digest\":\"\(d)\"}"
            #expect(try #require(ReleaseInfo.parse(json(assets: assets))).zip == nil, "\(d)")
        }
        let none = "{\"name\":\"ColimaBar.zip\",\"size\":10}"
        #expect(try #require(ReleaseInfo.parse(json(assets: none))).zip == nil)
    }

    @Test func aSizeOverTheLimitGivesNoZip() throws {
        func zip(_ size: Int) throws -> ReleaseInfo.Asset? {
            let assets = "{\"name\":\"ColimaBar.zip\",\"size\":\(size),\"digest\":\"sha256:\(digest)\"}"
            return try #require(ReleaseInfo.parse(json(assets: assets))).zip
        }
        #expect(try zip(UpdatePolicy.maxZipBytes) != nil)
        #expect(try zip(UpdatePolicy.maxZipBytes + 1) == nil)
        #expect(try zip(0) == nil)
        #expect(try zip(-5) == nil)
    }

    @Test func aTagThatIsNotAVersionGivesNoZip() throws {
        #expect(try #require(ReleaseInfo.parse(json(tag: "v1.0.0-rc1"))).zip == nil)
    }
}
