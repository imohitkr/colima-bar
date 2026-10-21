import Testing

@testable import ColimaBar

@Suite struct DomainNameTests {
    @Test func labelsBecomeDNSLabels() {
        #expect(DomainName.label("Web_App") == "web-app")
        #expect(DomainName.label("my.svc") == "my-svc")
        #expect(DomainName.label("my svc") == "my-svc")
        #expect(DomainName.label("--a--") == "a")
        #expect(DomainName.label("a__b") == "a-b")
        #expect(DomainName.label("Ünïcode") == "ncode")
        #expect(DomainName.label("___") == nil)
        #expect(DomainName.label("") == nil)
    }

    @Test func aLongLabelIsCutAndTrimmed() {
        #expect(DomainName.label(String(repeating: "a", count: 70)) == String(repeating: "a", count: 63))
        let cutAtDash = String(repeating: "a", count: 62) + "-" + "b"
        #expect(DomainName.label(cutAtDash) == String(repeating: "a", count: 62))
    }

    @Test func hostsAreNormalized() {
        #expect(DomainName.normalizedHost("Web.Shop.LOCALHOST:8080") == "web.shop.localhost")
        #expect(DomainName.normalizedHost("x.localhost.") == "x.localhost")
        #expect(DomainName.normalizedHost("localhost") == "localhost")
    }

    @Test func hostsThatAreNoNamesAreRejected() {
        for raw in ["[::1]:80", "[::1]", "127.0.0.1", "127.0.0.1:80", "", ":80", "a..b", "a_b.localhost", ".localhost"]
        {
            #expect(DomainName.normalizedHost(raw) == nil, "\(raw)")
        }
        #expect(DomainName.normalizedHost(String(repeating: "a", count: 254)) == nil)
        #expect(DomainName.normalizedHost(String(repeating: "a", count: 64) + ".localhost") == nil)
    }

    @Test func relativeNamesUseTheLongestSuffix() {
        let suffixes = ["localhost", "colima.localhost"]
        #expect(DomainName.relative("web.shop.localhost", suffixes: suffixes) == "web.shop")
        #expect(DomainName.relative("web.colima.localhost", suffixes: suffixes) == "web")
        #expect(DomainName.relative("localhost", suffixes: suffixes) == "")
        #expect(DomainName.relative("evil.com", suffixes: suffixes) == nil)
        #expect(DomainName.relative("notlocalhost", suffixes: suffixes) == nil)
    }

    @Test func relativeNamesAreChecked() {
        for good in ["web", "admin.shop", "a-b.c", "a.b.c.d.e.f.g.h"] {
            #expect(DomainName.isValidRelative(good), "\(good)")
        }
        let tooMany = "a.b.c.d.e.f.g.h.i"
        let tooLong = Array(repeating: String(repeating: "a", count: 50), count: 5).joined(separator: ".")
        for bad in ["", ".a", "a.", "a..b", "-a", "a-", "A", "a_b", "a b", tooMany, tooLong] {
            #expect(!DomainName.isValidRelative(bad), "\(bad)")
        }
    }
}
