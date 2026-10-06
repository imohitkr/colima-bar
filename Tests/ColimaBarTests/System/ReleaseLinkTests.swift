import Foundation
import Testing

@testable import ColimaBar

@Suite struct ReleaseLinkTests {
    private func trusted(_ s: String) -> Bool { ReleaseLink.isTrusted(URL(string: s)!) }

    @Test func acceptsThisRepoReleasePages() {
        #expect(trusted("https://github.com/imohitkr/colima-bar/releases/tag/v0.4.0"))
        #expect(trusted("https://github.com/imohitkr/colima-bar/releases/latest"))
        #expect(trusted("HTTPS://GitHub.com/imohitkr/colima-bar/releases/tag/v1.0.0"))
    }

    @Test func rejectsOtherSchemes() {
        #expect(!trusted("http://github.com/imohitkr/colima-bar/releases/tag/v0.4.0"))
        #expect(!trusted("file:///imohitkr/colima-bar/releases/x"))
        #expect(!trusted("file:///Applications/Calculator.app"))
        #expect(!trusted("x-apple.systempreferences:com.apple.Notifications-Settings.extension"))
        #expect(!trusted("colimabar://github.com/imohitkr/colima-bar/releases/x"))
    }

    @Test func rejectsOtherHostsAndRepos() {
        #expect(!trusted("https://evil.example/imohitkr/colima-bar/releases/tag/v0.4.0"))
        #expect(!trusted("https://github.com.evil.example/imohitkr/colima-bar/releases/tag/v0.4.0"))
        #expect(!trusted("https://github.com@evil.example/imohitkr/colima-bar/releases/tag/v0.4.0"))
        #expect(!trusted("https://github.com:8443/imohitkr/colima-bar/releases/tag/v0.4.0"))
        #expect(!trusted("https://github.com/someone/colima-bar/releases/tag/v0.4.0"))
        #expect(!trusted("https://github.com/imohitkr/colima-bar-fork/releases/tag/v0.4.0"))
        #expect(!trusted("https://github.com/imohitkr/colima-bar/issues/1"))
        #expect(!trusted("https://github.com/imohitkr/colima-bar/releases/../../other/repo"))
    }

    @Test func pageFallsBackToLatest() {
        let good = URL(string: "https://github.com/imohitkr/colima-bar/releases/tag/v0.4.0")!
        #expect(ReleaseLink.page(good) == good)
        #expect(
            ReleaseLink.page(URL(string: "http://github.com/imohitkr/colima-bar/releases/tag/v0.4.0")!)
                == ReleaseLink.latest)
        #expect(ReleaseLink.page(nil) == ReleaseLink.latest)
        #expect(ReleaseLink.latest.absoluteString == "https://github.com/imohitkr/colima-bar/releases/latest")
    }

    @Test func buildsThePageFromAValidTag() {
        #expect(
            ReleaseLink.page(tag: "v0.5.0").absoluteString
                == "https://github.com/imohitkr/colima-bar/releases/tag/v0.5.0")
        #expect(
            ReleaseLink.page(tag: "1.2.3").absoluteString == "https://github.com/imohitkr/colima-bar/releases/tag/1.2.3"
        )
    }

    @Test func otherTagsGiveTheLatestPage() {
        for t in [
            "v0.5.0/../../x/y", "v1.2", "v1.2.3.4", "v1.2.3-rc1", "", "v", "v1..3", "%2e%2e", "v1.2.3%2f",
            "v1.2.3?x=1", "v1.2.3#x", "v١.٢.٣", "v1.2.3 ", "V1.2.3",
        ] {
            #expect(ReleaseLink.page(tag: t) == ReleaseLink.latest, "\(t)")
        }
    }

    @Test func encodedDotSegmentsAreNotTrusted() {
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
