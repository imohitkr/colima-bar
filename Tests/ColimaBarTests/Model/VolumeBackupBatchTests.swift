import Foundation
import Testing

@testable import ColimaBar

@Suite @MainActor struct VolumeBackupBatchTests {
    private let id = String(repeating: "ab", count: 32)

    private struct Scenario {
        var imageStatus = 200
        var loadStatus = 200
        var missing: Set<String> = []
    }

    private func daemon(_ s: Scenario) throws -> FakeDaemon {
        let id = self.id
        let d = FakeDaemon(path: TestSocketPath.unique()) { req in
            let line = req.line
            if line.hasPrefix("GET /images/colimabar-helper:1/json") { return .init(status: s.imageStatus) }
            if line.hasPrefix("GET /info") { return .init(body: Data(#"{"Architecture":"aarch64"}"#.utf8)) }
            if line.hasPrefix("POST /images/load") {
                return .init(status: s.loadStatus, body: Data(#"{"message":"no"}"#.utf8))
            }
            if line.hasPrefix("POST /containers/create") {
                return .init(status: 201, body: Data(#"{"Id":"\#(id)"}"#.utf8))
            }
            if line.hasPrefix("GET /containers/\(id)/archive") { return .init(chunks: [TarFixture.volume()]) }
            if line.hasPrefix("DELETE /containers/") { return .init(status: 204) }
            if line.hasPrefix("GET /volumes/") {
                let name = String(line.dropFirst("GET /volumes/".count).split(separator: " ")[0])
                if s.missing.contains(name) { return .init(status: 404) }
                return .init(body: Data(#"{"Name":"\#(name)","Driver":"local"}"#.utf8))
            }
            return .init(status: 404)
        }
        try d.start()
        return d
    }

    private func runner(_ d: FakeDaemon) -> VolumeBackupRunner {
        VolumeBackupRunner(api: DockerAPI(socketPath: d.path), newSuffix: { "cafe0001" })
    }

    private func items(_ names: [String], in folder: TempFolder) -> [VolumeBackupBatch.Item] {
        names.map { .init(name: $0, size: 1, destination: folder.path + "/\($0).tar") }
    }

    private func run(
        _ r: VolumeBackupRunner, _ items: [VolumeBackupBatch.Item], replace: Bool = false,
        started: Counter = Counter(), afterStart: @escaping @MainActor (Int) -> Void = { _ in }
    ) async -> VolumeBackupBatch.Summary {
        await VolumeBackupBatch.run(
            runner: r, items: items, replace: replace, app: "ColimaBar test",
            willStart: { i, _ in
                started.add()
                afterStart(i)
            }, onProgress: { _ in })
    }

    @Test func eachVolumeGetsItsOwnFile() async throws {
        let d = try daemon(Scenario(imageStatus: 200))
        defer { d.stop() }
        let folder = try TempFolder()
        let summary = await run(runner(d), items(["a", "b"], in: folder))
        #expect(summary.done.map(\.name) == ["a", "b"] && summary.done.map(\.file) == ["a.tar", "b.tar"])
        #expect(summary.failed.isEmpty && !summary.cancelled && summary.prepareFailure == nil)
        #expect(FileManager.default.fileExists(atPath: folder.path + "/a.tar"))
        #expect(FileManager.default.fileExists(atPath: folder.path + "/b.tar"))
    }

    @Test func aFailedImageLoadStopsBeforeTheFirstVolume() async throws {
        let d = try daemon(Scenario(imageStatus: 404, loadStatus: 500))
        defer { d.stop() }
        let folder = try TempFolder()
        let started = Counter()
        let summary = await run(runner(d), items(["a", "b"], in: folder), started: started)
        #expect(summary.prepareFailure != nil && summary.done.isEmpty && started.value == 0)
        #expect(!summary.started)
    }

    @Test func aCancelBetweenVolumesKeepsTheFinishedFileAndStopsTheLoop() async throws {
        let d = try daemon(Scenario())
        defer { d.stop() }
        let folder = try TempFolder()
        let r = runner(d)
        // The cancel comes while the first volume starts: the next one never starts.
        let started = Counter()
        let summary = await run(
            r, items(["a", "b", "c"], in: folder), started: started,
            afterStart: { i in if i == 0 { r.cancel() } })
        #expect(summary.cancelled && started.value == 1 && summary.done.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: folder.path + "/b.tar"))
    }

    @Test func aCancelBeforeTheLoopIsNotAFailure() async throws {
        let d = try daemon(Scenario())
        defer { d.stop() }
        let folder = try TempFolder()
        let r = runner(d)
        r.cancel()
        let summary = await run(r, items(["a"], in: folder))
        #expect(summary.cancelled && !summary.started && summary.prepareFailure == nil && summary.failed.isEmpty)
    }

    @Test func aFileThatExistsCountsAsFailedAndStaysAsItWas() async throws {
        let d = try daemon(Scenario())
        defer { d.stop() }
        let folder = try TempFolder()
        try "old".write(toFile: folder.path + "/a.tar", atomically: true, encoding: .utf8)
        let summary = await run(runner(d), items(["a", "b"], in: folder))
        #expect(summary.failed == [.init(name: "a", reason: VolumeBackupRunner.exists.reason, removedFile: false)])
        #expect(summary.done.map(\.name) == ["b"])
        #expect(try String(contentsOfFile: folder.path + "/a.tar", encoding: .utf8) == "old")
    }

    @Test func aVolumeThatIsGoneCountsAsFailedAndTheLoopGoesOn() async throws {
        let d = try daemon(Scenario(missing: ["a"]))
        defer { d.stop() }
        let folder = try TempFolder()
        let summary = await run(runner(d), items(["a", "b"], in: folder))
        #expect(summary.failed.map(\.name) == ["a"] && summary.failed.first?.removedFile == false)
        #expect(summary.done.map(\.name) == ["b"])
    }

    @Test func aSingleVolumeAndManyVolumesGiveTheNotificationsOfTheirOwn() async throws {
        let d = try daemon(Scenario())
        defer { d.stop() }
        let folder = try TempFolder()
        let one = await run(runner(d), items(["a"], in: folder))
        let oneText = ColimaModel.backupMessage(summary: one, volumes: ["a"], folder: nil, because: nil)
        #expect(oneText?.hasPrefix("Backed up volume a to a.tar (") == true)
        let many = await run(runner(d), items(["b", "c"], in: folder))
        let manyText = ColimaModel.backupMessage(summary: many, volumes: ["b", "c"], folder: "Backups", because: nil)
        #expect(manyText == "Backed up 2 volumes to Backups.")
    }
}
