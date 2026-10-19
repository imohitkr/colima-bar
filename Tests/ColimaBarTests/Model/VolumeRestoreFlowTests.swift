import Foundation
import Testing

@testable import ColimaBar

@Suite @MainActor struct VolumeRestoreFlowTests {
    private let id = String(repeating: "cd", count: 32)

    private struct Scenario {
        var volumeExists = true
        var probeArchive = TarFixture.directory("v/") + TarFixture.endMarker
        var users = "[]"
        var putStatus = 200
        var volume = #"{"Name":"data","Driver":"local","Labels":{"own":"label"}}"#
        var deleteVolumeStatus = 204
        var createVolumeStatus = 201
    }

    private func daemon(_ s: Scenario) throws -> FakeDaemon {
        let id = self.id
        let d = FakeDaemon(path: TestSocketPath.unique()) { req in
            let line = req.line
            if line.hasPrefix("GET /images/") { return .init(status: 200) }
            if line.hasPrefix("GET /volumes/data") {
                return s.volumeExists ? .init(body: Data(s.volume.utf8)) : .init(status: 404)
            }
            if line.hasPrefix("GET /containers/json") { return .init(body: Data(s.users.utf8)) }
            if line.hasPrefix("POST /containers/create") {
                return .init(status: 201, body: Data(#"{"Id":"\#(id)"}"#.utf8))
            }
            if line.hasPrefix("GET /containers/\(id)/archive") { return .init(chunks: [s.probeArchive]) }
            if line.hasPrefix("PUT /containers/\(id)/archive") { return .init(status: s.putStatus) }
            if line.hasPrefix("DELETE /containers/") { return .init(status: 204) }
            if line.hasPrefix("DELETE /volumes/") { return .init(status: s.deleteVolumeStatus) }
            if line.hasPrefix("POST /volumes/create") {
                return .init(status: s.createVolumeStatus, body: Data("{}".utf8))
            }
            return .init(status: 404)
        }
        try d.start()
        return d
    }

    private struct Fixture {
        let path: String
        let scan: TarFileScan.Summary
        let folder: TempFolder
    }

    private func fixture(name: String = "data", labels: [String: String] = [:]) throws -> Fixture {
        let folder = try TempFolder()
        let meta = VolumeBackupMeta(name: name, labels: labels)
        let file = meta.entry() + TarFixture.volume()
        let path = folder.path + "/b.tar"
        try file.write(to: URL(fileURLWithPath: path))
        return Fixture(path: path, scan: try TarFileScan.scan(path: path), folder: folder)
    }

    private func run(
        _ d: FakeDaemon, _ f: Fixture, target: String = "data", isNew: Bool, confirm: Bool = true,
        asked: Counter = Counter(), sent: Counter = Counter()
    ) async -> VolumeRestoreFlow.Outcome {
        let runner = VolumeBackupRunner(api: DockerAPI(socketPath: d.path), newSuffix: { "cafe0001" })
        return await VolumeRestoreFlow.run(
            runner: runner, file: f.path, scan: f.scan, target: target, isNew: isNew,
            confirmReplace: { _ in
                asked.add()
                return confirm
            }, willSend: { sent.add() }, onProgress: { _ in })
    }

    private func requests(_ d: FakeDaemon, _ prefix: String) -> [FakeDaemon.Request] {
        d.seenRequests.filter { $0.line.hasPrefix(prefix) }
    }

    @Test func aNewVolumeIsCreatedWithTheLabelsOfTheFileWhenTheNameIsTheSame() async throws {
        let d = try daemon(Scenario(volumeExists: false))
        defer { d.stop() }
        let f = try fixture(labels: ["com.docker.compose.project": "shop"])
        let sent = Counter()
        #expect(await run(d, f, isNew: true, sent: sent) == .done)
        let create = try #require(requests(d, "POST /volumes/create").first)
        let body = try #require(JSONSerialization.jsonObject(with: create.body) as? [String: Any])
        #expect(body["Labels"] as? [String: String] == ["com.docker.compose.project": "shop"])
        #expect(requests(d, "PUT ").count == 1 && sent.value == 1)
    }

    @Test func aNewVolumeWithAnotherNameGetsNoLabels() async throws {
        let d = try daemon(Scenario(volumeExists: false))
        defer { d.stop() }
        let f = try fixture(name: "other", labels: ["a": "b"])
        _ = await run(d, f, isNew: true)
        let create = try #require(requests(d, "POST /volumes/create").first)
        let body = try #require(JSONSerialization.jsonObject(with: create.body) as? [String: Any])
        #expect((body["Labels"] as? [String: String])?.isEmpty == true)
    }

    @Test func aNewVolumeNeverReplacesAVolumeWithTheSameName() async throws {
        let d = try daemon(Scenario(volumeExists: true))
        defer { d.stop() }
        let outcome = await run(d, try fixture(), isNew: true)
        #expect(outcome == .failed("A volume named data exists."))
        #expect(requests(d, "PUT ").isEmpty && requests(d, "POST /volumes/create").isEmpty)
    }

    @Test func aFailedRestoreRemovesTheVolumeThatItCreated() async throws {
        let d = try daemon(Scenario(volumeExists: false, putStatus: 500))
        defer { d.stop() }
        let outcome = await run(d, try fixture(), isNew: true)
        guard case .failed = outcome else {
            Issue.record("expected a failure")
            return
        }
        #expect(requests(d, "DELETE /volumes/data").count == 1)
    }

    @Test func anEmptyVolumeIsRestoredWithoutAQuestion() async throws {
        let d = try daemon(Scenario())
        defer { d.stop() }
        let asked = Counter()
        #expect(await run(d, try fixture(), isNew: false, asked: asked) == .done)
        #expect(asked.value == 0 && requests(d, "DELETE /volumes/").isEmpty && requests(d, "PUT ").count == 1)
    }

    @Test func aVolumeWithFilesAsksAndKeepsItWhenTheUserSaysNo() async throws {
        let d = try daemon(Scenario(probeArchive: TarFixture.volume()))
        defer { d.stop() }
        let asked = Counter()
        #expect(await run(d, try fixture(), isNew: false, confirm: false, asked: asked) == .declined)
        #expect(asked.value == 1)
        #expect(requests(d, "DELETE /volumes/").isEmpty && requests(d, "PUT ").isEmpty)
    }

    @Test func aConfirmedReplaceDeletesTheVolumeAndCreatesItWithItsOwnLabels() async throws {
        let d = try daemon(Scenario(probeArchive: TarFixture.volume()))
        defer { d.stop() }
        let f = try fixture(labels: ["from": "file"])
        #expect(await run(d, f, isNew: false) == .done)
        let sequence = d.seen.filter {
            $0.hasPrefix("DELETE /volumes/") || $0.hasPrefix("POST /volumes/") || $0.hasPrefix("PUT ")
        }
        #expect(
            sequence.map { String($0.split(separator: " ")[0] + " " + $0.split(separator: " ")[1]) }
                == ["DELETE /volumes/data", "POST /volumes/create", "PUT /containers/\(id)/archive?path=/"])
        let create = try #require(requests(d, "POST /volumes/create").first)
        let body = try #require(JSONSerialization.jsonObject(with: create.body) as? [String: Any])
        #expect(body["Labels"] as? [String: String] == ["own": "label"])
    }

    @Test func containersThatUseAVolumeWithFilesRefuseTheRestore() async throws {
        let users = #"[{"Id":"1","Names":["/db"],"Image":"x","State":"running","Status":"Up"}]"#
        let d = try daemon(Scenario(probeArchive: TarFixture.volume(), users: users))
        defer { d.stop() }
        let asked = Counter()
        let outcome = await run(d, try fixture(), isNew: false, asked: asked)
        #expect(
            outcome
                == .refused(
                    "Containers use volume data: db. Remove them first, or restore to a new volume."))
        #expect(asked.value == 0 && requests(d, "DELETE /volumes/").isEmpty && requests(d, "PUT ").isEmpty)
    }

    @Test func aMissingVolumeFailsAnExistingVolumeRestore() async throws {
        let d = try daemon(Scenario(volumeExists: false))
        defer { d.stop() }
        let outcome = await run(d, try fixture(), isNew: false)
        #expect(outcome == .failed("The volume does not exist any more."))
    }

    @Test func aCancelBeforeTheRestoreEndsAsCancelled() async throws {
        let d = try daemon(Scenario())
        defer { d.stop() }
        let runner = VolumeBackupRunner(api: DockerAPI(socketPath: d.path), newSuffix: { "cafe0001" })
        runner.cancel()
        let f = try fixture()
        let outcome = await VolumeRestoreFlow.run(
            runner: runner, file: f.path, scan: f.scan, target: "data", isNew: false, confirmReplace: { _ in true },
            willSend: {}, onProgress: { _ in })
        #expect(outcome == .cancelled(.nothing) && requests(d, "PUT ").isEmpty)
    }

    @Test func aRestoreSendsTheFileWithoutTheColimaBarEntry() async throws {
        let d = try daemon(Scenario())
        defer { d.stop() }
        let f = try fixture()
        _ = await run(d, f, isNew: false)
        let put = try #require(requests(d, "PUT ").first)
        #expect(put.body == TarFixture.volume())
    }

    // MARK: - Replace

    @Test func aVolumeWithDriverOptionsIsNeverReplaced() async throws {
        let volume = #"{"Name":"data","Driver":"local","Options":{"type":"nfs","device":":/x"}}"#
        let d = try daemon(Scenario(probeArchive: TarFixture.volume(), volume: volume))
        defer { d.stop() }
        let asked = Counter()
        let outcome = await run(d, try fixture(), isNew: false, asked: asked)
        #expect(outcome == .refused(ColimaModel.restoreMessage(driverOptionsOf: "data")))
        #expect(asked.value == 0 && requests(d, "DELETE /volumes/").isEmpty && requests(d, "PUT ").isEmpty)
    }

    @Test func aVolumeWithAnotherDriverIsNeverReplaced() async throws {
        let volume = #"{"Name":"data","Driver":"rexray","Options":null}"#
        let d = try daemon(Scenario(probeArchive: TarFixture.volume(), volume: volume))
        defer { d.stop() }
        let outcome = await run(d, try fixture(), isNew: false)
        #expect(outcome == .refused(ColimaModel.restoreMessage(driverOptionsOf: "data")))
        #expect(requests(d, "DELETE /volumes/").isEmpty)
    }

    @Test func anEmptyVolumeWithDriverOptionsStillTakesARestore() async throws {
        let volume = #"{"Name":"data","Driver":"local","Options":{"type":"tmpfs","device":"tmpfs"}}"#
        let d = try daemon(Scenario(volume: volume))
        defer { d.stop() }
        #expect(await run(d, try fixture(), isNew: false) == .done)
        #expect(requests(d, "DELETE /volumes/").isEmpty)
    }

    @Test func aCancelAfterTheReplaceQuestionChangesNothing() async throws {
        let d = try daemon(Scenario(probeArchive: TarFixture.volume()))
        defer { d.stop() }
        let runner = VolumeBackupRunner(api: DockerAPI(socketPath: d.path), newSuffix: { "cafe0001" })
        let f = try fixture()
        let outcome = await VolumeRestoreFlow.run(
            runner: runner, file: f.path, scan: f.scan, target: "data", isNew: false,
            confirmReplace: { _ in
                runner.cancel()
                return true
            }, willSend: {}, onProgress: { _ in })
        #expect(outcome == .cancelled(.nothing))
        #expect(requests(d, "DELETE /volumes/").isEmpty && requests(d, "POST /volumes/create").isEmpty)
    }

    @Test func aFailedUploadAfterAReplaceSaysThatTheOldFilesAreGone() async throws {
        let d = try daemon(Scenario(probeArchive: TarFixture.volume(), putStatus: 500))
        defer { d.stop() }
        let outcome = await run(d, try fixture(), isNew: false)
        guard case .notice(let text) = outcome else {
            Issue.record("expected a notice")
            return
        }
        #expect(text.contains("The old files of volume data are deleted."))
        #expect(text.contains("holds part of the backup") && text.contains("Restore again from b.tar."))
    }

    @Test func aFailedCreateAfterAReplaceSaysThatTheVolumeIsGone() async throws {
        let d = try daemon(Scenario(probeArchive: TarFixture.volume(), createVolumeStatus: 500))
        defer { d.stop() }
        let outcome = await run(d, try fixture(), isNew: false)
        guard case .notice(let text) = outcome else {
            Issue.record("expected a notice")
            return
        }
        #expect(text.contains("The old files of volume data are deleted."))
        #expect(text.contains("The volume does not exist now.") && text.contains("Restore again from b.tar."))
        #expect(requests(d, "PUT ").isEmpty)
    }

    @Test func aFailedDeleteInAReplaceKeepsTheOldFiles() async throws {
        let d = try daemon(Scenario(probeArchive: TarFixture.volume(), deleteVolumeStatus: 409))
        defer { d.stop() }
        guard case .failed = await run(d, try fixture(), isNew: false) else {
            Issue.record("expected a failure")
            return
        }
        #expect(requests(d, "POST /volumes/create").isEmpty && requests(d, "PUT ").isEmpty)
    }

    // MARK: - New volume

    @Test func aNewNameThatAVolumeTookMeanwhileIsNotUsedAndNotDeleted() async throws {
        // Docker answers a create of an existing volume with success: it has files.
        let d = try daemon(Scenario(volumeExists: false, probeArchive: TarFixture.volume()))
        defer { d.stop() }
        let outcome = await run(d, try fixture(), isNew: true)
        #expect(outcome == .refused(ColimaModel.restoreMessage(volumeExistsNow: "data")))
        #expect(requests(d, "PUT ").isEmpty && requests(d, "DELETE /volumes/").isEmpty)
    }

    @Test func aNewNameThatAContainerUsesMeanwhileIsNotUsedAndNotDeleted() async throws {
        let users = #"[{"Id":"1","Names":["/db"],"Image":"x","State":"running","Status":"Up"}]"#
        let d = try daemon(Scenario(volumeExists: false, users: users))
        defer { d.stop() }
        let outcome = await run(d, try fixture(), isNew: true)
        #expect(outcome == .refused(ColimaModel.restoreMessage(volumeExistsNow: "data")))
        #expect(requests(d, "PUT ").isEmpty && requests(d, "DELETE /volumes/").isEmpty)
    }

    @Test func aFailedUploadToANewVolumeWithAFailedCleanUpTellsTheUser() async throws {
        let d = try daemon(Scenario(volumeExists: false, putStatus: 500, deleteVolumeStatus: 409))
        defer { d.stop() }
        let outcome = await run(d, try fixture(), isNew: true)
        guard case .notice(let text) = outcome else {
            Issue.record("expected a notice")
            return
        }
        #expect(text.contains("Restore failed:"))
        #expect(text.contains("ColimaBar could not remove the new volume data. Remove it in the Volumes tab."))
    }

    @Test func aCancelledRestoreToANewVolumeSaysThatItRemovedTheVolume() async throws {
        let d = try daemon(Scenario(volumeExists: false))
        defer { d.stop() }
        let runner = VolumeBackupRunner(api: DockerAPI(socketPath: d.path), newSuffix: { "cafe0001" })
        let f = try fixture()
        let outcome = await VolumeRestoreFlow.run(
            runner: runner, file: f.path, scan: f.scan, target: "data", isNew: true, confirmReplace: { _ in true },
            willSend: { runner.cancel() }, onProgress: { _ in })
        #expect(outcome == .cancelled(.newVolumeRemoved))
        #expect(requests(d, "DELETE /volumes/data").count == 1)
    }

    @Test func aCancelledRestoreToAnEmptyVolumeSaysThatItCanHoldPartOfTheFiles() async throws {
        let d = try daemon(Scenario())
        defer { d.stop() }
        let runner = VolumeBackupRunner(api: DockerAPI(socketPath: d.path), newSuffix: { "cafe0001" })
        let f = try fixture()
        let outcome = await VolumeRestoreFlow.run(
            runner: runner, file: f.path, scan: f.scan, target: "data", isNew: false, confirmReplace: { _ in true },
            willSend: { runner.cancel() }, onProgress: { _ in })
        #expect(outcome == .cancelled(.partial))
    }
}
