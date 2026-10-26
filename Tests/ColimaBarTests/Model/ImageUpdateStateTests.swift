import Foundation
import Testing

@testable import ColimaBar

@Suite struct ImageUpdateStateTests {
    private let d1 = "sha256:" + String(repeating: "1", count: 64)
    private let d2 = "sha256:" + String(repeating: "2", count: 64)
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let nginx = "docker.io/library/nginx:latest"

    private func container(
        _ id: String, image: String = "nginx", imageID: String = "sha256:aaa", state: String = "running",
        project: String? = nil
    ) -> Container {
        Container(
            id: id, name: id, image: image, state: state, status: "Up", ports: [], project: project, imageID: imageID)
    }

    private func local(_ id: String = "sha256:aaa", digests: [String]? = nil) -> ImageUpdateCheck.LocalImage {
        .init(id: id, repoDigests: digests ?? ["nginx@\(d1)"])
    }

    private func make(
        _ list: [Container], config: [String: String], images: [String: ImageUpdateCheck.LocalImage],
        entries: [String: ImageUpdateCache.Entry] = [:]
    ) -> ImageUpdateState {
        .make(containers: list, configImages: config, local: images, entries: entries)
    }

    @Test func aContainerOfAnOutdatedTagShowsAnUpdateAndAnImageShowsIt() {
        let state = make(
            [container("a"), container("b")], config: ["a": "nginx", "b": "nginx"], images: [nginx: local()],
            entries: [nginx: .init(digest: d2, checkedAt: now)])
        #expect(state.containers["a"] == .update(digest: d2))
        #expect(state.images[nginx] == .update(digest: d2))
        #expect(state.updateRefs.map(\.normalized) == [nginx])
        #expect(state.lastCheck == now && state.failureCount == 0)
    }

    @Test func aContainerOfAnOldImageShowsARecreate() {
        let state = make(
            [container("a", imageID: "sha256:old")], config: ["a": "nginx"], images: [nginx: local()])
        #expect(state.containers["a"] == .recreate)
        #expect(state.images[nginx] == .current)
        #expect(state.updateRefs.isEmpty)
    }

    @Test func pinnedAndUnreadableReferencesAreSkipped() {
        let state = make(
            [container("a"), container("b"), container("c")],
            config: ["a": "nginx@\(d1)", "b": "Bad Ref", "c": "local/build"], images: [:])
        #expect(state.containers["a"] == .skipped(.pinned))
        #expect(state.containers["b"] == .skipped(.unparsable))
        #expect(state.containers["c"] == .skipped(.localOnly))
        #expect(state.checkable.isEmpty)
    }

    @Test func aContainerWithoutAConfigImageHasNoStatus() {
        #expect(make([container("a")], config: [:], images: [:]).containers.isEmpty)
    }

    @Test func onlyReferencesWithPulledImagesCanBeChecked() {
        let state = make(
            [container("a"), container("b", image: "local/build")], config: ["a": "nginx", "b": "local/build"],
            images: [nginx: local(), "docker.io/local/build:latest": local(digests: [])])
        #expect(state.checkable.map(\.normalized) == [nginx])
    }

    @Test func failuresAreCountedByKindAndShownInTheCaption() {
        let entries: [String: ImageUpdateCache.Entry] = [
            nginx: .init(error: .signInNeeded, checkedAt: now.addingTimeInterval(-3 * 3600)),
            "docker.io/library/redis:latest": .init(digest: d1, checkedAt: now.addingTimeInterval(-7200)),
        ]
        let state = make(
            [container("a"), container("b", image: "redis")], config: ["a": "nginx", "b": "redis"],
            images: [nginx: local(), "docker.io/library/redis:latest": local(digests: ["redis@\(d1)"])],
            entries: entries)
        #expect(state.failures == [.signInNeeded: 1])
        #expect(state.lastCheck == now.addingTimeInterval(-7200))
        #expect(state.caption(now: now) == "Last check 2 h ago · 1 image could not be checked")
        #expect(ImageUpdateState().caption(now: now) == "Not checked yet")
    }

    @Test func theCaptionNamesSeveralFailuresInThePlural() {
        var state = ImageUpdateState()
        state.lastCheck = now
        state.failures = [.rateLimited: 2, .notFound: 1]
        #expect(state.caption(now: now) == "Last check just now · 3 images could not be checked")
    }

    @Test func anAgeIsShownInTheLargestUnit() {
        func age(_ s: TimeInterval) -> String { ImageUpdateState.age(of: now.addingTimeInterval(-s), now: now) }
        #expect(age(5) == "just now")
        #expect(age(5 * 60) == "5 min ago")
        #expect(age(3 * 3600) == "3 h ago")
        #expect(age(47 * 3600) == "47 h ago")
        #expect(age(72 * 3600) == "3 d ago")
        #expect(ImageUpdateState.age(of: now.addingTimeInterval(60), now: now) == "just now")
    }

    @Test func aStoppedContainerHasNoBadge() {
        let running = container("a", imageID: "sha256:old")
        let stopped = container("b", imageID: "sha256:old", state: "exited")
        let state = make([running, stopped], config: ["a": "nginx", "b": "nginx"], images: [nginx: local()])
        #expect(state.badge(for: running) == .recreate)
        #expect(state.badge(for: stopped) == nil)
        #expect(state.containers["b"] == .recreate)
    }

    @Test func aCurrentOrSkippedContainerHasNoBadge() {
        let c = container("a")
        let state = make([c], config: ["a": "nginx"], images: [nginx: local()])
        #expect(state.badge(for: c) == nil)
    }

    @Test func theUpdatesOfAProjectAreTheReferencesOfItsContainers() {
        let web = container("a", project: "shop")
        let other = container("b", image: "redis")
        let state = make(
            [web, other], config: ["a": "nginx", "b": "redis"],
            images: [nginx: local(), "docker.io/library/redis:latest": local(digests: ["redis@\(d1)"])],
            entries: [
                nginx: .init(digest: d2, checkedAt: now),
                "docker.io/library/redis:latest": .init(digest: d2, checkedAt: now),
            ])
        #expect(state.updateRefs.count == 2)
        #expect(state.updateRefs(of: [web], configImages: ["a": "nginx", "b": "redis"]).map(\.normalized) == [nginx])
    }
}
