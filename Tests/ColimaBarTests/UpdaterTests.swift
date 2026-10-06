import Foundation
import Testing
@testable import ColimaBar

@Suite struct ReleasePageTests {
    @Test func buildsThePageFromAValidTag() {
        #expect(ReleaseLink.page(tag: "v0.5.0").absoluteString == "https://github.com/imohitkr/colima-bar/releases/tag/v0.5.0")
        #expect(ReleaseLink.page(tag: "1.2.3").absoluteString == "https://github.com/imohitkr/colima-bar/releases/tag/1.2.3")
    }

    @Test func otherTagsGiveTheLatestPage() {
        for t in ["v0.5.0/../../x/y", "v1.2", "v1.2.3.4", "v1.2.3-rc1", "", "v", "v1..3", "%2e%2e", "v1.2.3%2f",
                  "v1.2.3?x=1", "v1.2.3#x", "v١.٢.٣", "v1.2.3 ", "V1.2.3"] {
            #expect(ReleaseLink.page(tag: t) == ReleaseLink.latest, "\(t)")
        }
    }

    @Test func encodedDotSegmentsAreNotTrusted() {
        func trusted(_ s: String) -> Bool { ReleaseLink.isTrusted(URL(string: s)!) }
        #expect(!trusted("https://github.com/imohitkr/colima-bar/releases/%2e%2e/%2e%2e/x/y"))
        #expect(!trusted("https://github.com/imohitkr/colima-bar/releases/%2E%2e/%2E%2E/x/y"))
        #expect(!trusted("https://github.com/imohitkr/colima-bar/releases/.%2e/x"))
        #expect(!trusted("https://github.com/imohitkr/colima-bar/releases/%2e/tag/v1.0.0"))
        #expect(!trusted("https://github.com/imohitkr/colima-bar/releases/tag/v1.0.0/."))
        #expect(!trusted("https://github.com/imohitkr/colima-bar/releases/..%2f..%2fx"))
        #expect(trusted("https://github.com/imohitkr/colima-bar/releases/tag/v1.0.0"))
        #expect(trusted("https://github.com/imohitkr/colima-bar/releases/tag/v1.0.0..1"))
    }
}
