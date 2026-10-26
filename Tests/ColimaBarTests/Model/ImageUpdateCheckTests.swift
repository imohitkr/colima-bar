import Foundation
import Testing

@testable import ColimaBar

@Suite struct ImageUpdateCheckTests {
    private let ref = ImageRef.parse("nginx:latest")!
    private let d1 = "sha256:" + String(repeating: "1", count: 64)
    private let d2 = "sha256:" + String(repeating: "2", count: 64)
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func local(id: String = "sha256:aaa", digests: [String]? = nil) -> ImageUpdateCheck.LocalImage {
        .init(id: id, repoDigests: digests ?? ["nginx@\(d1)"])
    }

    private func status(
        container: String = "sha256:aaa", local: ImageUpdateCheck.LocalImage?, remote: ImageUpdateCache.Entry? = nil
    ) -> ImageUpdateStatus {
        ImageUpdateCheck.status(ref: ref, containerImageID: container, local: local, remote: remote)
    }

    @Test func aMatchingImageAndDigestIsCurrent() {
        #expect(status(local: local(), remote: .init(digest: d1, checkedAt: now)) == .current)
        #expect(status(local: local()) == .current)
    }

    @Test func aDigestThatTheLocalImageLacksIsAnUpdate() {
        #expect(status(local: local(), remote: .init(digest: d2, checkedAt: now)) == .update(digest: d2))
    }

    @Test func aNewerImageUnderTheTagIsARecreate() {
        #expect(status(container: "sha256:old", local: local()) == .recreate)
        #expect(status(container: "sha256:old", local: local(), remote: .init(digest: d1, checkedAt: now)) == .recreate)
    }

    @Test func anUpdateBeatsARecreate() {
        let remote = ImageUpdateCache.Entry(digest: d2, checkedAt: now)
        #expect(status(container: "sha256:old", local: local(), remote: remote) == .update(digest: d2))
    }

    @Test func aContainerWithoutAnImageIDNeverNeedsARecreate() {
        #expect(status(container: "", local: local()) == .current)
    }

    @Test func aPulledDigestEndsTheUpdate() {
        let remote = ImageUpdateCache.Entry(digest: d2, checkedAt: now, pulled: true)
        #expect(status(local: local(), remote: remote) == .current)
    }

    @Test func aLocalImageWithoutDigestsOfItsRepositoryIsSkipped() {
        #expect(status(local: local(digests: [])) == .skipped(.localOnly))
        // A digest of another repository, for example after docker tag, says nothing.
        #expect(status(local: local(digests: ["other/app@\(d1)"])) == .skipped(.localOnly))
        #expect(status(local: nil) == .skipped(.localOnly))
    }

    @Test func aFailedCheckShowsOnlyWithoutAnythingElseToShow() {
        let failed = ImageUpdateCache.Entry(error: .signInNeeded, checkedAt: now)
        #expect(status(local: local(), remote: failed) == .failed(.signInNeeded))
        #expect(status(container: "sha256:old", local: local(), remote: failed) == .recreate)
    }

    @Test func aRepositoryMatchesThroughTheShortNameOfDockerHub() {
        let both = local(digests: ["nginx@\(d1)", "docker.io/library/nginx@\(d2)"])
        #expect(ImageUpdateCheck.digests(in: both.repoDigests, of: ref) == [d1, d2])
    }

    @Test func containerReferencesAreParsedOrSkipped() throws {
        #expect(try ImageUpdateCheck.reference(of: "nginx").get().normalized == "docker.io/library/nginx:latest")
        #expect(throws: ImageUpdateStatus.Reason.pinned) {
            try ImageUpdateCheck.reference(of: "nginx@\(d1)").get()
        }
        #expect(throws: ImageUpdateStatus.Reason.pinned) { try ImageUpdateCheck.reference(of: d1).get() }
        #expect(throws: ImageUpdateStatus.Reason.unparsable) { try ImageUpdateCheck.reference(of: "Bad Ref").get() }
        #expect(throws: ImageUpdateStatus.Reason.unparsable) { try ImageUpdateCheck.reference(of: nil).get() }
    }

    @Test(
        "failures are classified",
        arguments: [
            (nil as Int?, nil as String?, ImageUpdateStatus.Failure.unreachable),
            (401, nil, .signInNeeded),
            (403, nil, .signInNeeded),
            (500, "pull access denied for x", .signInNeeded),
            (500, "Get \"https://r/v2/\": unauthorized: authentication required", .signInNeeded),
            (404, nil, .notFound),
            (500, "manifest unknown: manifest unknown", .notFound),
            (429, nil, .rateLimited),
            (500, "toomanyrequests: You have reached your pull rate limit", .rateLimited),
            (500, "Get https://r: dial tcp: lookup r: no such host", .unreachable),
            (503, "net/http: request canceled (i/o timeout)", .unreachable),
            (500, "something else", .other),
            (400, nil, .other),
        ])
    func classifies(status: Int?, message: String?, expected: ImageUpdateStatus.Failure) {
        #expect(ImageUpdateCheck.classify(status: status, message: message) == expected)
    }

    @Test func messagesAreCutToOneLineOf120Characters() {
        #expect(ImageUpdateCheck.shortened("a\nb") == "a b")
        let long = String(repeating: "x", count: 300)
        #expect(ImageUpdateCheck.shortened(long).count == 120)
        #expect(ImageUpdateCheck.shortened(long).hasSuffix("…"))
        #expect(ImageUpdateCheck.shortened("short") == "short")
    }

    @Test func aPlatformIsSentOnlyForAnImageOfAnotherArchitecture() {
        func image(_ arch: String, variant: String? = nil) -> ImageUpdateCheck.LocalImage {
            .init(id: "x", repoDigests: [], os: "linux", architecture: arch, variant: variant)
        }
        #expect(ImageUpdateCheck.platform(of: image("arm64"), hostArchitecture: "arm64") == nil)
        #expect(ImageUpdateCheck.platform(of: image("arm64"), hostArchitecture: "aarch64") == nil)
        #expect(ImageUpdateCheck.platform(of: image("amd64"), hostArchitecture: "aarch64") == "linux/amd64")
        #expect(ImageUpdateCheck.platform(of: image("arm", variant: "v7"), hostArchitecture: "arm64") == "linux/arm/v7")
        #expect(ImageUpdateCheck.platform(of: image("amd64"), hostArchitecture: nil) == nil)
        #expect(ImageUpdateCheck.platform(of: .init(id: "x", repoDigests: []), hostArchitecture: "arm64") == nil)
    }
}
