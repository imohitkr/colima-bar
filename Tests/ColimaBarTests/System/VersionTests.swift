import Foundation
import Testing

@testable import ColimaBar

@Suite struct VersionTests {
    @Test func comparesNumerically() {
        #expect(Version.isNewer("0.10.0", than: "0.9.9"))
        #expect(Version.isNewer("v0.3.0", than: "0.2.0"))
        #expect(Version.isNewer("1.0", than: "0.99.99"))
        #expect(!Version.isNewer("0.2.0", than: "0.2.0"))
        #expect(!Version.isNewer("0.1.9", than: "0.2.0"))
    }

    @Test func ignoresBuildSuffixesAndPadsMissingParts() {
        #expect(!Version.isNewer("0.2.0", than: "0.2.0-4-gabc123-dirty"))
        #expect(Version.isNewer("0.2.1", than: "0.2.0-4-gabc123"))
        #expect(!Version.isNewer("0.2", than: "0.2.0"))
    }

    @Test func devBuildsNeverNag() {
        #expect(!Version.isNewer("0.3.0", than: "dev"))
        #expect(!Version.isNewer("garbage", than: "0.1.0"))
    }
}
