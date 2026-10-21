import Foundation
import Testing

@testable import ColimaBar

@Suite struct CleanupReportTests {
    private func hex64(_ n: Int) -> String {
        let digits = String(n, radix: 16)
        return String(repeating: "0", count: 64 - digits.count) + digits
    }
    private func sha(_ n: Int) -> String { "sha256:" + hex64(n) }

    @Test func imagesAreSortedBySizeAndCutAtTheLimit() throws {
        let images = (1...12).map { DFFixture.image(sha($0), tags: ["app\($0):1"], size: Int64($0) * 100) }
        let report = CleanupReport.make(from: try DFFixture.df(images: images))
        #expect(report.images.items.count == 10)
        #expect(report.images.items.first?.title == "app12:1")
        #expect(report.images.hiddenCount == 2)
        #expect(report.images.hiddenSize == 300)  // 100 + 200
        #expect(report.images.count == 12)
    }

    @Test func anImageInUseHasNoRemoval() throws {
        let df = try DFFixture.df(images: [DFFixture.image(sha(1), tags: ["web:1"], size: 10, containers: 1)])
        let item = try #require(CleanupReport.make(from: df).images.items.first)
        #expect(item.inUse)
        #expect(item.removal == nil)
    }

    @Test func anImageWithTwoTagsHasNoRemoval() throws {
        let df = try DFFixture.df(images: [DFFixture.image(sha(1), tags: ["web:1", "web:latest"], size: 10)])
        let item = try #require(CleanupReport.make(from: df).images.items.first)
        #expect(item.title == "web:1 +1 tag")
        #expect(item.removal == nil)
    }

    @Test func anUnusedImageWithOneTagIsRemovedByItsTag() throws {
        let df = try DFFixture.df(images: [DFFixture.image(sha(1), tags: ["web:1"], size: 10)])
        let item = try #require(CleanupReport.make(from: df).images.items.first)
        #expect(item.removal == .init(action: .imageRemove, args: ["web:1"]))
    }

    @Test func aDanglingImageIsRemovedByItsShortID() throws {
        let id = sha(0xabcdef)
        let df = try DFFixture.df(images: [
            DFFixture.image(id, tags: nil, size: 10), DFFixture.image(sha(2), tags: ["<none>:<none>"], size: 5),
        ])
        let items = CleanupReport.make(from: df).images.items
        let first = try #require(items.first)
        #expect(first.title == "<none>")
        let short = String(id.dropFirst(7).prefix(12))
        #expect(short.count == 12)
        #expect(first.removal == .init(action: .imageRemove, args: [short]))
        #expect(items.count == 2 && items[1].removal != nil)
    }

    @Test func imageReclaimableSkipsImagesInUseAndSharedLayers() throws {
        let df = try DFFixture.df(images: [
            DFFixture.image(sha(1), tags: ["a:1"], size: 100, containers: 1),
            DFFixture.image(sha(2), tags: ["b:1"], size: 80, shared: 30),
        ])
        #expect(CleanupReport.make(from: df).images.reclaimable == 50)
    }

    @Test func onlyUnusedVolumesAreListed() throws {
        let df = try DFFixture.df(volumes: [
            DFFixture.volume("used", size: 500, refs: 1),
            DFFixture.volume("pgdata", size: 300, labels: #"{"com.docker.compose.project":"shop"}"#),
            DFFixture.volume("anon", size: 100, labels: #"{"com.docker.volume.anonymous":""}"#),
        ])
        let volumes = CleanupReport.make(from: df).volumes
        #expect(volumes.items.map(\.title) == ["pgdata", "anon"])
        #expect(volumes.items.map(\.detail) == ["compose: shop", "anonymous"])
        #expect(volumes.items[0].removal == .init(action: .volumeRemove, args: ["pgdata"]))
        #expect(volumes.reclaimable == 400)
    }

    @Test func aVolumeWithNoUsageDataIsNotListed() throws {
        let df = try DFFixture.df(volumes: [
            DFFixture.volume("nodata", size: nil), DFFixture.volume("negative", size: -1),
        ])
        let volumes = CleanupReport.make(from: df).volumes
        #expect(volumes.items.map(\.title) == ["negative"])
        #expect(volumes.items.allSatisfy { $0.size == 0 })
        #expect(volumes.reclaimable == 0)
    }

    @Test func pausedAndRestartingContainersAreNotStopped() throws {
        let df = try DFFixture.df(containers: [
            DFFixture.container("1", name: "paused", state: "paused", size: 5),
            DFFixture.container("2", name: "loop", state: "restarting", size: 5),
            DFFixture.container("3", name: "made", state: "created", size: 1),
            DFFixture.container("4", name: "dead", state: "dead", size: 2),
            DFFixture.container("5", name: "done", state: "exited", size: 4),
        ])
        let containers = CleanupReport.make(from: df).containers
        #expect(Set(containers.items.map(\.title)) == ["made", "dead", "done"])
        #expect(containers.reclaimable == 7)
    }

    @Test func anUnnamedContainerIsNeitherListedNorReclaimable() throws {
        let text = #"{"Containers":[{"Id":"1","Names":[],"State":"exited","SizeRw":50}]}"#
        let df = try JSONDecoder().decode(APIDF.self, from: Data(text.utf8))
        let containers = CleanupReport.make(from: df).containers
        #expect(containers.isEmpty && containers.reclaimable == 0)
    }

    @Test func helperContainersGetNoLogRow() throws {
        let helper = #"{"com.imohitkr.colimabar.helper":"1"}"#
        let (a, b, _) = ids
        let df = try DFFixture.df(containers: [
            DFFixture.container(a, name: "api", state: "running"),
            DFFixture.container(b, name: "colimabar-helper-1", state: "running", labels: helper),
        ])
        let report = CleanupReport.make(from: df)
        #expect(report.logItems([a: 1, b: 2]).items.map(\.title) == ["api"])
    }

    @Test func onlyStoppedContainersAreListedWithoutHelpers() throws {
        let helper = #"{"com.imohitkr.colimabar.helper":"1"}"#
        let sidecar = "colimabar-debug-" + String(repeating: "a", count: 12)
        let df = try DFFixture.df(containers: [
            DFFixture.container("1", name: "web", state: "running", size: 10),
            DFFixture.container("2", name: "old-api", size: 110),
            DFFixture.container("3", name: "colimabar-helper-1", labels: helper),
            DFFixture.container("4", name: sidecar),
        ])
        let containers = CleanupReport.make(from: df).containers
        #expect(containers.items.map(\.title) == ["old-api"])
        #expect(containers.items.first?.removal == .init(action: .containerRemove, args: ["old-api"]))
        #expect(containers.reclaimable == 110)
    }

    @Test func buildCacheRowsHaveNoRemovalAndReclaimableSkipsInUseAndShared() throws {
        let df = try DFFixture.df(cache: [
            DFFixture.cache("a", type: "exec.cachemount", size: 900, description: "mount / from exec"),
            DFFixture.cache("b", size: 100, inUse: true),
            DFFixture.cache("c", size: 50, shared: true),
        ])
        let cache = CleanupReport.make(from: df).buildCache
        #expect(cache.items.allSatisfy { $0.removal == nil })
        #expect(cache.reclaimable == 900)
        #expect(cache.items.first?.title == "mount / from exec")
        #expect(cache.items.first?.detail == "Cache mount")
    }

    @Test func buildCacheWithoutADescriptionUsesTheTypeAsTitle() throws {
        let df = try DFFixture.df(cache: [DFFixture.cache("a", type: "regular", size: 10)])
        let item = try #require(CleanupReport.make(from: df).buildCache.items.first)
        #expect(item.title == "Layer")
        #expect(CleanupReport.cacheKind("source.local") == "Build context")
        #expect(CleanupReport.cacheKind("frontend") == "frontend")
        #expect(CleanupReport.cacheKind(nil) == "Cache")
    }

    @Test func buildCacheShowsFewerRowsAndShortensTheDescription() throws {
        let long = String(repeating: "x", count: 100)
        let rows = (1...7).map {
            DFFixture.cache("id\($0)", size: Int64($0), description: long, lastUsed: "2026-01-02T03:04:05.123456789Z")
        }
        let cache = CleanupReport.make(from: try DFFixture.df(cache: rows)).buildCache
        #expect(cache.items.count == CleanupReport.cacheRowLimit)
        #expect(cache.hiddenCount == 2)
        let first = try #require(cache.items.first)
        #expect(first.title == String(repeating: "x", count: 60))
        #expect(first.detail.hasPrefix("Layer · last used "))
    }

    @Test func aLastUsedDateThatDoesNotParseIsSkipped() throws {
        let df = try DFFixture.df(cache: [DFFixture.cache("a", size: 1, description: "d", lastUsed: "yesterday")])
        #expect(CleanupReport.make(from: df).buildCache.items.first?.detail == "Layer")
    }

    @Test func equalSizesKeepAStableOrder() throws {
        let images = ["c", "a", "b"].enumerated().map {
            DFFixture.image(sha($0.offset + 1), tags: ["\($0.element):1"], size: 5)
        }
        let one = CleanupReport.make(from: try DFFixture.df(images: images))
        let two = CleanupReport.make(from: try DFFixture.df(images: images.reversed()))
        #expect(one.images.items.map(\.title) == ["a:1", "b:1", "c:1"])
        #expect(two.images.items.map(\.title) == ["a:1", "b:1", "c:1"])
    }

    // MARK: - Logs

    private var ids: (String, String, String) {
        (String(repeating: "a1", count: 32), String(repeating: "b2", count: 32), String(repeating: "c3", count: 32))
    }

    @Test func logItemsUseTheContainerNamesAndDropUnknownIDs() throws {
        let (a, b, gone) = ids
        let df = try DFFixture.df(containers: [
            DFFixture.container(a, name: "api", state: "running"), DFFixture.container(b, name: "worker"),
        ])
        let report = CleanupReport.make(from: df)
        let logs = report.logItems([a: 180, b: 50, gone: 999])
        #expect(logs.items.map(\.title) == ["api", "worker"])
        #expect(logs.items.map(\.size) == [180, 50])
    }

    @Test func logItemsEmptyALogWithTheIDAndTheName() throws {
        let (a, _, _) = ids
        let df = try DFFixture.df(containers: [DFFixture.container(a, name: "api", state: "running")])
        let item = try #require(CleanupReport.make(from: df).logItems([a: 5]).items.first)
        #expect(item.kind == .log)
        #expect(item.removal == .init(action: .logTruncate, args: [a, "api"]))
    }

    @Test func logItemsAreCutAtTheLimit() throws {
        let rows = (0..<12).map { hex64($0) }
        let df = try DFFixture.df(containers: rows.enumerated().map { DFFixture.container($1, name: "c\($0)") })
        let sizes = Dictionary(uniqueKeysWithValues: rows.enumerated().map { ($1, Int64($0 + 1)) })
        let logs = CleanupReport.make(from: df).logItems(sizes)
        #expect(logs.items.count == 10 && logs.hiddenCount == 2 && logs.hiddenSize == 3)
    }

    @Test func anEmptyDFGivesTheEmptyReport() throws {
        #expect(CleanupReport.make(from: try DFFixture.df()).isEmpty)
    }
}
