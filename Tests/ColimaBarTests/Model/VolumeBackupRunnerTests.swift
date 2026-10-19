import Foundation
import Testing

@testable import ColimaBar

@Suite struct VolumeBackupRunnerTests {
    private let id = String(repeating: "ab", count: 32)
    private let container = "colimabar-helper-cafe0001"

    private struct Scenario {
        var imageExists = false
        var archive: [Data] = []
        var archiveStatus = 200
        var holdOpen = false
        var putStatus = 200
        var putBody = Data()
        var volumeDeleteStatus = 204
        var containerDeleteStatus = 204
        var imageDeleteStatus = 200
        var loadBody = Data(#"{"stream":"Loaded image: colimabar-helper:1\n"}"#.utf8)
        var list = Data("[]".utf8)
    }

    private func daemon(_ s: Scenario) throws -> FakeDaemon {
        let id = self.id
        let d = FakeDaemon(path: TestSocketPath.unique()) { req in
            let line = req.line
            if line.hasPrefix("GET /images/colimabar-helper:1/json") { return .init(status: s.imageExists ? 200 : 404) }
            if line.hasPrefix("GET /info") { return .init(body: Data(#"{"Architecture":"aarch64"}"#.utf8)) }
            if line.hasPrefix("POST /images/load") { return .init(body: s.loadBody) }
            if line.hasPrefix("POST /containers/create") {
                return .init(status: 201, body: Data(#"{"Id":"\#(id)","Warnings":[]}"#.utf8))
            }
            if line.hasPrefix("GET /containers/\(id)/archive") {
                if s.archiveStatus != 200 {
                    return .init(status: s.archiveStatus, body: Data(#"{"message":"x"}"#.utf8))
                }
                return .init(chunks: s.archive, holdOpen: s.holdOpen)
            }
            if line.hasPrefix("PUT /containers/\(id)/archive") { return .init(status: s.putStatus, body: s.putBody) }
            if line.hasPrefix("DELETE /containers/") { return .init(status: s.containerDeleteStatus) }
            if line.hasPrefix("DELETE /images/") { return .init(status: s.imageDeleteStatus) }
            if line.hasPrefix("DELETE /volumes/") { return .init(status: s.volumeDeleteStatus) }
            if line.hasPrefix("POST /volumes/create") { return .init(status: 201, body: Data("{}".utf8)) }
            if line.hasPrefix("GET /volumes/") {
                return .init(
                    body: Data(
                        #"{"Name":"data","Driver":"local","Labels":{"a":"b"},"CreatedAt":"2026-01-01T00:00:00Z"}"#.utf8)
                )
            }
            if line.hasPrefix("GET /containers/json") { return .init(body: s.list) }
            return .init(status: 404)
        }
        try d.start()
        return d
    }

    private func runner(_ d: FakeDaemon) -> VolumeBackupRunner {
        VolumeBackupRunner(api: DockerAPI(socketPath: d.path), newSuffix: { "cafe0001" })
    }

    private func lines(_ d: FakeDaemon) -> [String] {
        d.seen.map { $0.replacingOccurrences(of: " HTTP/1.0", with: "") }
    }

    private func chunks(_ data: Data, size: Int = 700) -> [Data] {
        stride(from: 0, to: data.count, by: size).map { data[$0..<min($0 + size, data.count)] }
    }

    private func jsonBody(_ r: FakeDaemon.Request) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: r.body) as? [String: Any])
    }

    // MARK: - Backup

    @Test func aBackupRunsTheFullSequenceAndWritesAPrivateFile() async throws {
        let archive = TarFixture.volume(files: [("v/f", "hi"), ("v/sub/g", String(repeating: "x", count: 3000))])
        let d = try daemon(Scenario(archive: chunks(archive)))
        defer { d.stop() }
        let folder = try TempFolder()
        let dest = folder.path + "/data.tar"
        let r = runner(d)
        #expect(await r.prepare() == nil)
        let meta = VolumeBackupMeta(name: "data", labels: ["a": "b"])
        let result = await r.backUp(volume: "data", meta: meta, to: dest, replace: true, onProgress: { _ in })
        await r.release()

        #expect(result == .success(Int64(meta.entry().count + archive.count)))
        #expect(
            lines(d) == [
                "GET /images/colimabar-helper:1/json",
                "GET /info",
                "POST /images/load?quiet=1",
                "POST /containers/create?name=\(container)",
                "GET /containers/\(id)/archive?path=/v",
                "DELETE /containers/\(id)?force=1",
                "DELETE /images/colimabar-helper:1",
            ])
        #expect(try Data(contentsOf: URL(fileURLWithPath: dest)) == meta.entry() + archive)
        var st = stat()
        stat(dest, &st)
        #expect(st.st_mode & 0o777 == 0o600)
    }

    @Test func theBackupContainerMountsTheVolumeReadOnlyWithBothLabels() async throws {
        let d = try daemon(Scenario(archive: [TarFixture.volume()]))
        defer { d.stop() }
        let folder = try TempFolder()
        _ = await runner(d).backUp(
            volume: "data", meta: VolumeBackupMeta(name: "data"), to: folder.path + "/a.tar", replace: true,
            onProgress: { _ in })
        let create = try #require(d.seenRequests.first { $0.line.hasPrefix("POST /containers/create") })
        let body = try jsonBody(create)
        let mount = try #require(((body["HostConfig"] as? [String: Any])?["Mounts"] as? [[String: Any]])?.first)
        #expect(mount["Source"] as? String == "data" && mount["ReadOnly"] as? Bool == true)
        #expect((body["Labels"] as? [String: String])?.count == 2)
    }

    @Test func theCleanUpNeverRemovesTheVolumeWithTheContainer() async throws {
        let d = try daemon(Scenario(archive: [TarFixture.volume()]))
        defer { d.stop() }
        let folder = try TempFolder()
        let r = runner(d)
        _ = await r.backUp(
            volume: "data", meta: VolumeBackupMeta(name: "data"), to: folder.path + "/a.tar", replace: true,
            onProgress: { _ in })
        #expect(d.seen.allSatisfy { !$0.contains("v=1") })
        #expect(d.seen.contains { $0.hasPrefix("DELETE /containers/\(id)?force=1") })
    }

    @Test func aCutStreamLeavesNoFileAndStillRemovesTheContainer() async throws {
        let cut = TarFixture.volume(files: [("v/f", String(repeating: "x", count: 5000))]).prefix(3000)
        let d = try daemon(Scenario(archive: chunks(Data(cut))))
        defer { d.stop() }
        let folder = try TempFolder()
        let result = await runner(d).backUp(
            volume: "data", meta: VolumeBackupMeta(name: "data"), to: folder.path + "/a.tar", replace: true,
            onProgress: { _ in })
        guard case .failure(let f) = result else {
            Issue.record("expected a failure")
            return
        }
        #expect(f.reason.contains("not complete") && !f.cancelled)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
        #expect(d.seen.contains { $0.hasPrefix("DELETE /containers/\(id)?force=1") })
    }

    @Test func anUnsafeEntryInTheStreamStopsTheBackup() async throws {
        let bad = TarFixture.directory("v/") + TarFixture.entry("../evil") + TarFixture.endMarker
        let d = try daemon(Scenario(archive: chunks(bad)))
        defer { d.stop() }
        let folder = try TempFolder()
        let result = await runner(d).backUp(
            volume: "data", meta: VolumeBackupMeta(name: "data"), to: folder.path + "/a.tar", replace: true,
            onProgress: { _ in })
        guard case .failure(let f) = result else {
            Issue.record("expected a failure")
            return
        }
        #expect(f.reason.contains("unsafe entry: ../evil"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
    }

    @Test func aDockerErrorStatusFailsTheBackup() async throws {
        let d = try daemon(Scenario(archiveStatus: 404))
        defer { d.stop() }
        let folder = try TempFolder()
        let result = await runner(d).backUp(
            volume: "data", meta: VolumeBackupMeta(name: "data"), to: folder.path + "/a.tar", replace: true,
            onProgress: { _ in })
        guard case .failure(let f) = result else {
            Issue.record("expected a failure")
            return
        }
        #expect(f.reason.contains("HTTP 404"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
    }

    @Test func aCancelDuringTheStreamLeavesNoFile() async throws {
        let archive = TarFixture.directory("v/") + TarFixture.entry("v/f", content: String(repeating: "x", count: 4000))
        let d = try daemon(Scenario(archive: chunks(archive), holdOpen: true))
        defer { d.stop() }
        let folder = try TempFolder()
        let r = runner(d)
        let dest = folder.path + "/a.tar"
        let task = Task {
            await r.backUp(
                volume: "data", meta: VolumeBackupMeta(name: "data"), to: dest, replace: true, onProgress: { _ in })
        }
        #expect(await waitUntil { d.seen.contains { $0.hasPrefix("GET /containers/\(self.id)/archive") } })
        r.cancel()
        let result = await task.value
        guard case .failure(let f) = result else {
            Issue.record("expected a cancel")
            return
        }
        #expect(f.cancelled && f.wroteFile)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
        #expect(await waitUntil { d.seen.contains { $0.hasPrefix("DELETE /containers/\(self.id)?force=1") } })
    }

    @Test func aBackupAfterACancelDoesNothing() async throws {
        let d = try daemon(Scenario())
        defer { d.stop() }
        let r = runner(d)
        r.cancel()
        let folder = try TempFolder()
        let result = await r.backUp(
            volume: "data", meta: VolumeBackupMeta(name: "data"), to: folder.path + "/a.tar", replace: true,
            onProgress: { _ in })
        #expect(result == .failure(.cancel) && d.seen.isEmpty)
    }

    @Test func withoutReplaceAnExistingFileStaysAndTheBackupFails() async throws {
        let d = try daemon(Scenario(archive: [TarFixture.volume()]))
        defer { d.stop() }
        let folder = try TempFolder()
        let dest = folder.path + "/a.tar"
        try "old".write(toFile: dest, atomically: true, encoding: .utf8)
        let result = await runner(d).backUp(
            volume: "data", meta: VolumeBackupMeta(name: "data"), to: dest, replace: false, onProgress: { _ in })
        #expect(result == .failure(VolumeBackupRunner.exists))
        #expect(try String(contentsOfFile: dest, encoding: .utf8) == "old" && d.seen.isEmpty)
    }

    @Test func theBackupReportsItsProgress() async throws {
        let archive = TarFixture.volume(files: [("v/big", String(repeating: "x", count: 100_000))])
        let d = try daemon(Scenario(archive: chunks(archive, size: 5000)))
        defer { d.stop() }
        let folder = try TempFolder()
        let last = LastValue()
        _ = await runner(d).backUp(
            volume: "data", meta: VolumeBackupMeta(name: "data"), to: folder.path + "/a.tar", replace: true,
            onProgress: { last.set($0) })
        #expect(last.value > 0 && last.value <= Int64(archive.count))
    }

    // MARK: - Restore

    @Test func aRestoreSendsTheFileFromTheSkipOffsetWithItsLength() async throws {
        let meta = VolumeBackupMeta(name: "data")
        let file = meta.entry() + TarFixture.volume(files: [("v/f", "hello")])
        let d = try daemon(Scenario())
        defer { d.stop() }
        let folder = try TempFolder()
        let path = folder.path + "/b.tar"
        try file.write(to: URL(fileURLWithPath: path))
        let last = LastValue()
        let failure = await runner(d).restore(
            file: path, skip: 1024, size: Int64(file.count), into: "data", onProgress: { last.set($0) })
        #expect(failure == nil)
        let put = try #require(d.seenRequests.first { $0.line.hasPrefix("PUT ") })
        #expect(put.line == "PUT /containers/\(id)/archive?path=/ HTTP/1.0")
        #expect(put.body == file.dropFirst(1024))
        #expect(put.headers["content-length"] == "\(file.count - 1024)")
        #expect(put.headers["content-type"] == "application/x-tar")
        #expect(last.value == Int64(file.count - 1024))
        #expect(d.seen.last == "DELETE /containers/\(id)?force=1 HTTP/1.0")
    }

    @Test func theRestoreContainerMountsTheVolumeWritable() async throws {
        let d = try daemon(Scenario())
        defer { d.stop() }
        let folder = try TempFolder()
        let path = folder.path + "/b.tar"
        let file = TarFixture.volume()
        try file.write(to: URL(fileURLWithPath: path))
        _ = await runner(d).restore(file: path, skip: 0, size: Int64(file.count), into: "data", onProgress: { _ in })
        let create = try #require(d.seenRequests.first { $0.line.hasPrefix("POST /containers/create") })
        let mount = try #require(
            ((try jsonBody(create))["HostConfig"] as? [String: Any])?["Mounts"] as? [[String: Any]])
        #expect(mount.first?["ReadOnly"] as? Bool == false)
    }

    @Test func aRestoreShowsTheMessageOfTheDaemon() async throws {
        let d = try daemon(Scenario(putStatus: 500, putBody: Data(#"{"message":"no space left on device"}"#.utf8)))
        defer { d.stop() }
        let folder = try TempFolder()
        let path = folder.path + "/b.tar"
        let file = TarFixture.volume()
        try file.write(to: URL(fileURLWithPath: path))
        let failure = await runner(d).restore(
            file: path, skip: 0, size: Int64(file.count), into: "data", onProgress: { _ in })
        #expect(failure?.reason == "no space left on device")
        #expect(d.seen.contains { $0.hasPrefix("DELETE /containers/\(id)?force=1") })
    }

    @Test func aRestoreOfAFileThatChangedSendsNothing() async throws {
        let d = try daemon(Scenario())
        defer { d.stop() }
        let folder = try TempFolder()
        let path = folder.path + "/b.tar"
        try TarFixture.volume().write(to: URL(fileURLWithPath: path))
        let failure = await runner(d).restore(file: path, skip: 0, size: 99, into: "data", onProgress: { _ in })
        #expect(failure?.reason.contains("changed") == true && d.seen.isEmpty)
    }

    // MARK: - Image

    @Test func prepareLoadsTheImageWithTheArchitectureOfTheVM() async throws {
        let d = try daemon(Scenario())
        defer { d.stop() }
        #expect(await runner(d).prepare() == nil)
        let load = try #require(d.seenRequests.first { $0.line.hasPrefix("POST /images/load?quiet=1") })
        #expect(load.body == HelperImage.archive(arch: "arm64"))
        #expect(load.headers["content-type"] == "application/x-tar")
    }

    @Test func prepareDoesNotLoadAnImageThatExists() async throws {
        let d = try daemon(Scenario(imageExists: true))
        defer { d.stop() }
        #expect(await runner(d).prepare() == nil)
        #expect(lines(d) == ["GET /images/colimabar-helper:1/json"])
    }

    @Test func prepareFailsWhenTheLoadReportsAnError() async throws {
        let d = try daemon(Scenario(loadBody: Data(#"{"error":"bad layer"}"#.utf8)))
        defer { d.stop() }
        #expect(await runner(d).prepare() != nil)
    }

    @Test func releaseIgnoresAConflict() async throws {
        let d = try daemon(Scenario(imageDeleteStatus: 409))
        defer { d.stop() }
        await runner(d).release()
        #expect(lines(d) == ["DELETE /images/colimabar-helper:1"])
    }

    // MARK: - Leftovers

    @Test func theSweepRemovesOnlyContainersWithBothLabelsAndThenTheImage() async throws {
        let list =
            #"[{"Id":"\#(id)","Names":["/colimabar-helper-1"],"Image":"x","State":"created","Status":"Created"}]"#
        let d = try daemon(Scenario(list: Data(list.utf8)))
        defer { d.stop() }
        await VolumeBackupRunner.sweepLeftovers(api: DockerAPI(socketPath: d.path))
        let first = try #require(d.seen.first)
        #expect(first.hasPrefix("GET /containers/json?all=1&filters="))
        let filter = first.removingPercentEncoding ?? first
        #expect(filter.contains("com.imohitkr.colimabar.helper=1") && filter.contains("helper.kind=volume"))
        #expect(lines(d).dropFirst() == ["DELETE /containers/\(id)?force=1", "DELETE /images/colimabar-helper:1"])
        #expect(d.seen.allSatisfy { !$0.contains("v=1") })
    }

    @Test func theSweepSkipsAnIDThatIsNotHex() async throws {
        let list = #"[{"Id":"../x","Names":["/a"],"Image":"x","State":"created","Status":"Created"}]"#
        let d = try daemon(Scenario(list: Data(list.utf8)))
        defer { d.stop() }
        await VolumeBackupRunner.sweepLeftovers(api: DockerAPI(socketPath: d.path))
        #expect(d.seen.filter { $0.hasPrefix("DELETE /containers/") }.isEmpty)
    }

    // MARK: - Volumes

    @Test func usersLeaveOutHelperContainers() async throws {
        let list = """
            [{"Id":"1","Names":["/db"],"Image":"x","State":"running","Status":"Up"},
             {"Id":"2","Names":["/colimabar-helper-1"],"Image":"x","State":"created","Status":"Created",
              "Labels":{"com.imohitkr.colimabar.helper":"1"}},
             {"Id":"3","Names":["/web"],"Image":"x","State":"exited","Status":"Exited"}]
            """
        let d = try daemon(Scenario(list: Data(list.utf8)))
        defer { d.stop() }
        #expect(await runner(d).users(of: "data", runningOnly: false) == ["db", "web"])
        let line = try #require(d.seen.first).removingPercentEncoding ?? ""
        #expect(line.contains("all=1") && line.contains(#""volume":["data"]"#))
    }

    @Test func runningUsersAskForRunningContainersOnly() async throws {
        let d = try daemon(Scenario())
        defer { d.stop() }
        _ = await runner(d).users(of: "data", runningOnly: true)
        let line = try #require(d.seen.first).removingPercentEncoding ?? ""
        #expect(line.contains(#""status":["running"]"#) && !line.contains("all=1"))
    }

    @Test func anEmptyVolumeShowsOnlyTheRootFolder() async throws {
        let d = try daemon(Scenario(archive: chunks(TarFixture.directory("v/") + TarFixture.endMarker)))
        defer { d.stop() }
        #expect(await runner(d).isEmpty(volume: "data") == .success(true))
        #expect(d.seen.contains { $0.hasPrefix("DELETE /containers/\(id)?force=1") })
    }

    @Test func aVolumeWithAFileIsNotEmptyAndTheProbeStopsEarly() async throws {
        let start = TarFixture.directory("v/") + TarFixture.entry("v/f", content: "x")
        let d = try daemon(Scenario(archive: chunks(start), holdOpen: true))
        defer { d.stop() }
        #expect(await runner(d).isEmpty(volume: "data") == .success(false))
    }

    @Test func theProbeMountsTheVolumeReadOnly() async throws {
        let d = try daemon(Scenario(archive: [TarFixture.directory("v/") + TarFixture.endMarker]))
        defer { d.stop() }
        _ = await runner(d).isEmpty(volume: "data")
        let create = try #require(d.seenRequests.first { $0.line.hasPrefix("POST /containers/create") })
        let mounts = ((try jsonBody(create))["HostConfig"] as? [String: Any])?["Mounts"] as? [[String: Any]]
        #expect(mounts?.first?["ReadOnly"] as? Bool == true)
    }

    @Test func lookupGivesTheFactsOfAVolume() async throws {
        let d = try daemon(Scenario())
        defer { d.stop() }
        guard case .found(let v) = await runner(d).lookup("data") else {
            Issue.record("expected found")
            return
        }
        #expect(v.Name == "data" && v.Labels == ["a": "b"] && v.CreatedAt == "2026-01-01T00:00:00Z")
    }

    @Test func createVolumeSendsThePlainLocalVolumeWithItsLabels() async throws {
        let d = try daemon(Scenario())
        defer { d.stop() }
        #expect(await runner(d).createVolume("data2", labels: ["a": "b"]) == nil)
        let body = try jsonBody(try #require(d.seenRequests.first))
        #expect(body["Name"] as? String == "data2" && body["Driver"] as? String == "local")
        #expect(body["Labels"] as? [String: String] == ["a": "b"] && body.count == 3)
    }

    @Test func deleteVolumeFailsWhileAContainerUsesIt() async throws {
        let d = try daemon(Scenario(volumeDeleteStatus: 409))
        defer { d.stop() }
        #expect(await runner(d).deleteVolume("data") != nil)
    }

    // MARK: - Failed clean-up

    @Test func aHelperContainerThatDockerCannotRemoveIsRemembered() async throws {
        let d = try daemon(
            Scenario(archive: [TarFixture.directory("v/") + TarFixture.endMarker], containerDeleteStatus: 500))
        defer { d.stop() }
        let r = runner(d)
        #expect(!r.leftHelperContainer)
        _ = await r.isEmpty(volume: "data")
        #expect(r.leftHelperContainer)
    }

    @Test func aHelperContainerThatIsGoneAlreadyIsNoProblem() async throws {
        let d = try daemon(
            Scenario(archive: [TarFixture.directory("v/") + TarFixture.endMarker], containerDeleteStatus: 404))
        defer { d.stop() }
        let r = runner(d)
        _ = await r.isEmpty(volume: "data")
        #expect(!r.leftHelperContainer)
    }

    @Test func theSweepStopsBeforeTheNextRemovalWhenATransferRuns() async throws {
        let list =
            #"[{"Id":"\#(id)","Names":["/a"],"Image":"x","State":"created","Status":"Created"}]"#
        let d = try daemon(Scenario(list: Data(list.utf8)))
        defer { d.stop() }
        await VolumeBackupRunner.sweepLeftovers(api: DockerAPI(socketPath: d.path), isBusy: { true })
        #expect(d.seen.filter { $0.hasPrefix("DELETE ") }.isEmpty)
    }

    @Test func theSweepKeepsTheImageWhenATransferStartsDuringIt() async throws {
        let list =
            #"[{"Id":"\#(id)","Names":["/a"],"Image":"x","State":"created","Status":"Created"}]"#
        let d = try daemon(Scenario(list: Data(list.utf8)))
        defer { d.stop() }
        let asked = Counter()
        await VolumeBackupRunner.sweepLeftovers(
            api: DockerAPI(socketPath: d.path),
            isBusy: {
                asked.add()
                return asked.value > 1
            })
        #expect(d.seen.filter { $0.hasPrefix("DELETE /containers/") }.count == 1)
        #expect(d.seen.filter { $0.hasPrefix("DELETE /images/") }.isEmpty)
    }

    // MARK: - Failure facts

    @Test func aBackupThatFailsAfterTheFileStartedSaysSo() async throws {
        let cut = TarFixture.volume(files: [("v/f", String(repeating: "x", count: 5000))]).prefix(3000)
        let d = try daemon(Scenario(archive: chunks(Data(cut))))
        defer { d.stop() }
        let folder = try TempFolder()
        let result = await runner(d).backUp(
            volume: "data", meta: VolumeBackupMeta(name: "data"), to: folder.path + "/a.tar", replace: true,
            onProgress: { _ in })
        guard case .failure(let f) = result else {
            Issue.record("expected a failure")
            return
        }
        #expect(f.wroteFile)
    }

    @Test func aBackupThatFindsAFileAtItsNameWroteNoFile() async throws {
        let d = try daemon(Scenario())
        defer { d.stop() }
        let folder = try TempFolder()
        let dest = folder.path + "/a.tar"
        try "old".write(toFile: dest, atomically: true, encoding: .utf8)
        let result = await runner(d).backUp(
            volume: "data", meta: VolumeBackupMeta(name: "data"), to: dest, replace: false, onProgress: { _ in })
        guard case .failure(let f) = result else {
            Issue.record("expected a failure")
            return
        }
        #expect(!f.wroteFile)
    }

    @Test func aFullDiskIsKnownByItsReason() {
        #expect(VolumeBackupRunner.failure(POSIXError(.ENOSPC)).isDiskFull)
        #expect(!VolumeBackupRunner.failure(POSIXError(.EACCES)).isDiskFull)
    }
}

/// The last value of a progress callback, from another thread.
/// `@unchecked Sendable`: `lock` guards `last`.
private final class LastValue: @unchecked Sendable {
    private let lock = NSLock()
    private var last: Int64 = 0
    func set(_ v: Int64) { lock.withLock { last = v } }
    var value: Int64 { lock.withLock { last } }
}
