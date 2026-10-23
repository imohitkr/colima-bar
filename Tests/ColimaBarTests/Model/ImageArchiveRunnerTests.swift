import CryptoKit
import Foundation
import Testing

@testable import ColimaBar

@Suite struct ImageArchiveRunnerTests {
    private struct Scenario {
        var archive: [Data] = []
        var getStatus = 200
        var holdOpen = false
        var loadStatus = 200
        var loadBody = Data(#"{"stream":"Loaded image: nginx:1\n"}"#.utf8)
        var inspect: [String: Int] = [:]
    }

    private func daemon(_ s: Scenario) throws -> FakeDaemon {
        let d = FakeDaemon(path: TestSocketPath.unique()) { req in
            let line = req.line
            if line.hasPrefix("GET /images/get") {
                if s.getStatus != 200 { return .init(status: s.getStatus, body: Data(#"{"message":"boom"}"#.utf8)) }
                return .init(chunks: s.archive, holdOpen: s.holdOpen)
            }
            if line.hasPrefix("POST /images/load") { return .init(status: s.loadStatus, body: s.loadBody) }
            if line.hasPrefix("GET /images/") {
                let ref = line.dropFirst("GET /images/".count).split(separator: "/json")[0]
                return .init(status: s.inspect[String(ref)] ?? 200, body: Data("{}".utf8))
            }
            return .init(status: 404)
        }
        try d.start()
        return d
    }

    private func runner(_ d: FakeDaemon) -> ImageArchiveRunner {
        ImageArchiveRunner(api: DockerAPI(socketPath: d.path))
    }

    private func imageTar() -> Data {
        TarFixture.entry("blobs/", flag: 0x35)
            + TarFixture.entry("blobs/sha256/abc", content: String(repeating: "x", count: 3000))
            + TarFixture.entry("manifest.json", content: "[]") + TarFixture.endMarker
    }

    private func chunks(_ data: Data, size: Int = 700) -> [Data] {
        stride(from: 0, to: data.count, by: size).map { data[$0..<min($0 + size, data.count)] }
    }

    private func sha(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    private func leftovers(_ folder: TempFolder) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
    }

    // MARK: Save

    @Test func aSaveWritesTheCompleteArchiveAndTheHashMatches() async throws {
        let tar = imageTar()
        let d = try daemon(Scenario(archive: chunks(tar)))
        defer { d.stop() }
        let folder = try TempFolder()
        let dest = folder.path + "/images.tar"
        let result = await runner(d).save(refs: ["nginx:1.27", "ghcr.io/a/b:v1"], to: dest, onProgress: { _ in })
        let saved = try result.get()
        #expect(saved.bytes == Int64(tar.count))
        #expect(saved.sha256 == sha(tar))
        #expect(try Data(contentsOf: URL(fileURLWithPath: dest)) == tar)
        var st = stat()
        stat(dest, &st)
        #expect(st.st_mode & 0o777 == 0o600)
        #expect(
            d.seen == ["GET /images/get?names=nginx%3A1%2E27&names=ghcr%2Eio%2Fa%2Fb%3Av1 HTTP/1.0"])
    }

    @Test func aStreamThatEndsEarlyFailsAndLeavesNoFile() async throws {
        let tar = imageTar()
        let d = try daemon(Scenario(archive: chunks(tar.dropLast(1024))))
        defer { d.stop() }
        let folder = try TempFolder()
        let result = await runner(d).save(refs: ["a:1"], to: folder.path + "/images.tar", onProgress: { _ in })
        guard case .failure(let f) = result else {
            Issue.record("a cut archive passed")
            return
        }
        #expect(f.reason.contains("not complete"))
        #expect(leftovers(folder).isEmpty)
    }

    @Test(arguments: [404, 500])
    func aDaemonErrorFailsAndLeavesNoFile(status: Int) async throws {
        let d = try daemon(Scenario(getStatus: status))
        defer { d.stop() }
        let folder = try TempFolder()
        let result = await runner(d).save(refs: ["a:1"], to: folder.path + "/images.tar", onProgress: { _ in })
        guard case .failure(let f) = result else {
            Issue.record("an error status passed")
            return
        }
        #expect(f.reason == "Docker cannot save the images (HTTP \(status)).")
        #expect(leftovers(folder).isEmpty)
    }

    @Test func anUnsafeEntryFailsTheSave() async throws {
        let tar = TarFixture.entry("/etc/passwd", content: "x") + TarFixture.endMarker
        let d = try daemon(Scenario(archive: [tar]))
        defer { d.stop() }
        let folder = try TempFolder()
        let result = await runner(d).save(refs: ["a:1"], to: folder.path + "/images.tar", onProgress: { _ in })
        guard case .failure(let f) = result else {
            Issue.record("an unsafe archive passed")
            return
        }
        #expect(f.reason == "The archive from Docker is not valid.")
        #expect(leftovers(folder).isEmpty)
    }

    @Test func aSaveNeverReplacesAFileAndNeverAsksForAllImages() async throws {
        let d = try daemon(Scenario(archive: [imageTar()]))
        defer { d.stop() }
        let folder = try TempFolder()
        let dest = folder.path + "/images.tar"
        try "mine".write(toFile: dest, atomically: true, encoding: .utf8)
        let r = runner(d)
        guard case .failure(let f) = await r.save(refs: ["a:1"], to: dest, onProgress: { _ in }) else {
            Issue.record("replaced a file")
            return
        }
        #expect(f == VolumeBackupRunner.exists)
        #expect(try String(contentsOfFile: dest, encoding: .utf8) == "mine")
        guard case .failure = await r.save(refs: [], to: folder.path + "/other.tar", onProgress: { _ in }) else {
            Issue.record("saved no refs")
            return
        }
        #expect(d.seen.isEmpty)
    }

    @Test func aCancelStopsTheSaveAndLeavesNoFile() async throws {
        let tar = imageTar()
        let d = try daemon(Scenario(archive: [tar.prefix(2000)], holdOpen: true))
        defer { d.stop() }
        let folder = try TempFolder()
        let r = runner(d)
        let dest = folder.path + "/images.tar"
        let saving = Task { await r.save(refs: ["a:1"], to: dest, onProgress: { _ in }) }
        #expect(await waitUntil { d.seen.count == 1 })
        r.cancel()
        guard case .failure(let f) = await saving.value else {
            Issue.record("a cancel passed")
            return
        }
        #expect(f.cancelled)
        #expect(leftovers(folder).isEmpty)
    }

    // MARK: Missing

    @Test func missingReadsTwoHundredAndFourOhFour() async throws {
        let d = try daemon(Scenario(inspect: ["nginx:1": 200, "redis:7": 404, "sha256:abc": 404]))
        defer { d.stop() }
        let gone = await runner(d).missing(["nginx:1", "redis:7", "sha256:abc"])
        #expect(gone == ["redis:7", "sha256:abc"])
        #expect(d.seen.first == "GET /images/nginx:1/json HTTP/1.0")
    }

    @Test func anotherStatusGivesNil() async throws {
        let d = try daemon(Scenario(inspect: ["nginx:1": 500]))
        defer { d.stop() }
        #expect(await runner(d).missing(["nginx:1"]) == nil)
    }

    // MARK: Load

    private func file(_ data: Data, in folder: TempFolder) throws -> String {
        let path = folder.path + "/images.tar"
        try data.write(to: URL(fileURLWithPath: path))
        return path
    }

    @Test func aLoadWithTheRightHashSendsTheFile() async throws {
        let tar = imageTar()
        let d = try daemon(Scenario())
        defer { d.stop() }
        let folder = try TempFolder()
        let path = try file(tar, in: folder)
        let failure = await runner(d).load(file: path, sha256: sha(tar), onProgress: { _ in })
        #expect(failure == nil)
        let post = try #require(d.seenRequests.first)
        #expect(post.line == "POST /images/load?quiet=1 HTTP/1.0")
        #expect(post.headers["content-type"] == "application/x-tar")
        #expect(post.body == tar)
    }

    @Test func aLoadWithAWrongHashSendsNothing() async throws {
        let tar = imageTar()
        let d = try daemon(Scenario())
        defer { d.stop() }
        let folder = try TempFolder()
        let path = try file(tar, in: folder)
        let failure = await runner(d).load(file: path, sha256: sha(Data("other".utf8)), onProgress: { _ in })
        #expect(failure == .text("The image file changed. ColimaBar does not load it."))
        #expect(d.seen.isEmpty)
    }

    @Test func aLoadRefusesAMissingFileAndASymlink() async throws {
        let d = try daemon(Scenario())
        defer { d.stop() }
        let folder = try TempFolder()
        let tar = imageTar()
        #expect(await runner(d).load(file: folder.path + "/none.tar", sha256: sha(tar), onProgress: { _ in }) != nil)
        let real = try file(tar, in: folder)
        let link = folder.path + "/link.tar"
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: real)
        #expect(await runner(d).load(file: link, sha256: sha(tar), onProgress: { _ in }) != nil)
        #expect(d.seen.isEmpty)
    }

    @Test func anErrorDetailInTheReplyIsAFailure() async throws {
        let tar = imageTar()
        let body = Data(
            ("{\"stream\":\"x\"}\n{\"errorDetail\":{\"message\":\"" + String(repeating: "m", count: 300)
                + "\"},\"error\":\"short\"}\n").utf8)
        let d = try daemon(Scenario(loadBody: body))
        defer { d.stop() }
        let folder = try TempFolder()
        let failure = await runner(d).load(file: try file(tar, in: folder), sha256: sha(tar), onProgress: { _ in })
        #expect(failure == .text(String(repeating: "m", count: 120)))
    }

    @Test func aNon2xxReplyIsAFailure() async throws {
        let tar = imageTar()
        let d = try daemon(Scenario(loadStatus: 500, loadBody: Data(#"{"message":"disk full"}"#.utf8)))
        defer { d.stop() }
        let folder = try TempFolder()
        let failure = await runner(d).load(file: try file(tar, in: folder), sha256: sha(tar), onProgress: { _ in })
        #expect(failure == .text("disk full"))
    }

    @Test func aCancelBeforeTheLoadSendsNothing() async throws {
        let tar = imageTar()
        let d = try daemon(Scenario())
        defer { d.stop() }
        let folder = try TempFolder()
        let r = runner(d)
        r.cancel()
        #expect(await r.load(file: try file(tar, in: folder), sha256: sha(tar), onProgress: { _ in }) == .cancel)
        #expect(d.seen.isEmpty)
    }
}
