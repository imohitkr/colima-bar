import Foundation
import Testing

@testable import ColimaBar

@Suite struct ImageUpdateRunnerTests {
    private let d1 = "sha256:" + String(repeating: "1", count: 64)
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func ok(_ json: String) -> FakeDaemon.Answer { .init(status: 200, body: Data(json.utf8)) }

    private func daemon(_ handler: @escaping FakeDaemon.Handler) throws -> (FakeDaemon, ImageUpdateRunner) {
        let socket = TestSocketPath.unique()
        let daemon = FakeDaemon(path: socket, handler: handler)
        try daemon.start()
        return (daemon, ImageUpdateRunner(api: DockerAPI(socketPath: socket)))
    }

    private func line(_ text: String) -> Data { Data((text + "\n").utf8) }

    // MARK: - Scan

    @Test func twoContainersOfOneImageReadTheImageOnce() async throws {
        let (daemon, runner) = try daemon { request in
            if request.line.contains("/images/") {
                return ok(#"{"Id":"sha256:aaa","RepoDigests":["nginx@\#(d1)"],"Os":"linux","Architecture":"arm64"}"#)
            }
            return ok(#"{"Id":"c","Config":{"Image":"nginx"},"Image":"sha256:aaa"}"#)
        }
        defer { daemon.stop() }
        let scan = try #require(await runner.scan(containerIDs: ["c1", "c2"], known: [:]))
        #expect(scan.configImages == ["c1": "nginx", "c2": "nginx"])
        #expect(scan.images["docker.io/library/nginx:latest"]?.id == "sha256:aaa")
        #expect(daemon.seen.filter { $0.contains("/images/") }.count == 1)
        #expect(daemon.seen.contains("GET /images/docker.io/library/nginx:latest/json HTTP/1.0"))
    }

    @Test func aKnownContainerIsNotReadAgain() async throws {
        let (daemon, runner) = try daemon { _ in ok(#"{"Id":"sha256:aaa","RepoDigests":[]}"#) }
        defer { daemon.stop() }
        let scan = try #require(await runner.scan(containerIDs: ["c1"], known: ["c1": "ghcr.io/o/a:1", "gone": "x"]))
        #expect(scan.configImages == ["c1": "ghcr.io/o/a:1"])
        #expect(daemon.seen == ["GET /images/ghcr.io/o/a:1/json HTTP/1.0"])
    }

    @Test func aPinnedOrBrokenReferenceIsNotAskedAbout() async throws {
        let (daemon, runner) = try daemon { _ in ok("{}") }
        defer { daemon.stop() }
        let scan = try #require(
            await runner.scan(containerIDs: ["a", "b"], known: ["a": "nginx@\(d1)", "b": "Bad Ref"]))
        #expect(scan.images.isEmpty)
        #expect(daemon.seen.isEmpty)
    }

    @Test func aGoneContainerAndAMissingImageGiveNoEntry() async throws {
        let (daemon, runner) = try daemon { _ in .init(status: 404) }
        defer { daemon.stop() }
        let scan = try #require(await runner.scan(containerIDs: ["c1"], known: [:]))
        #expect(scan == ImageUpdateRunner.Scan())
        let (daemon2, runner2) = try self.daemon { _ in .init(status: 404) }
        defer { daemon2.stop() }
        let scan2 = try #require(await runner2.scan(containerIDs: ["c1"], known: ["c1": "nginx"]))
        #expect(scan2.configImages == ["c1": "nginx"] && scan2.images.isEmpty)
    }

    @Test func aDaemonThatDoesNotAnswerGivesNoScan() async {
        let runner = ImageUpdateRunner(api: DockerAPI(socketPath: TestSocketPath.unique()))
        #expect(await runner.scan(containerIDs: ["c1"], known: [:]) == nil)
        #expect(await runner.hostArchitecture() == nil)
    }

    @Test func theHostArchitectureUsesTheNamesOfTheDockerAPI() async throws {
        let (daemon, runner) = try daemon { _ in ok(#"{"Architecture":"aarch64"}"#) }
        defer { daemon.stop() }
        #expect(await runner.hostArchitecture() == "arm64")
    }

    // MARK: - Registry

    @Test func theDigestComesFromTheDescriptor() async throws {
        let (daemon, runner) = try daemon { _ in ok(#"{"Descriptor":{"digest":"\#(d1)"}}"#) }
        defer { daemon.stop() }
        let ref = try #require(ImageRef.parse("ghcr.io/o/a:1"))
        let entry = await runner.distribution(ref, now: now)
        #expect(entry == .init(digest: d1, checkedAt: now))
        #expect(daemon.seen == ["GET /distribution/ghcr.io/o/a:1/json HTTP/1.0"])
    }

    @Test(
        "an error answer gives a failure kind",
        arguments: [
            (401, #"{"message":"unauthorized: authentication required"}"#, ImageUpdateStatus.Failure.signInNeeded),
            (404, #"{"message":"manifest unknown"}"#, .notFound),
            (429, #"{"message":"toomanyrequests"}"#, .rateLimited),
            (500, #"{"message":"Get x: dial tcp: i/o timeout"}"#, .unreachable),
            (500, #"{"message":"boom"}"#, .other),
            (200, "not json", .other),
            (200, #"{"Descriptor":{"digest":"md5:1"}}"#, .other),
        ])
    func classifiesTheAnswer(status: Int, body: String, expected: ImageUpdateStatus.Failure) async throws {
        let (daemon, runner) = try daemon { _ in .init(status: status, body: Data(body.utf8)) }
        defer { daemon.stop() }
        let entry = await runner.distribution(try #require(ImageRef.parse("a")), now: now)
        #expect(entry.error == expected && entry.digest == nil)
    }

    @Test func noAnswerIsUnreachable() async throws {
        let runner = ImageUpdateRunner(api: DockerAPI(socketPath: TestSocketPath.unique()))
        let entry = await runner.distribution(try #require(ImageRef.parse("a")), now: now)
        #expect(entry.error == .unreachable)
    }

    @Test func aRunStopsAskingARegistryAfterItsFirstRateLimitAnswer() async throws {
        let (daemon, runner) = try daemon { _ in .init(status: 429, body: Data(#"{"message":"toomanyrequests"}"#.utf8))
        }
        defer { daemon.stop() }
        let refs = ["a", "b", "c", "d"].compactMap(ImageRef.parse) + ["ghcr.io/o/x:1"].compactMap(ImageRef.parse)
        let answers = await runner.check(refs, now: now)
        // Two calls run at the same time, so at most two reach the registry before the stop.
        let hub = daemon.seen.filter { $0.contains("docker.io") }
        #expect((1...ImageUpdateSchedule.concurrency).contains(hub.count))
        #expect(answers.values.allSatisfy { $0.error == .rateLimited })
        #expect(answers.keys.contains("ghcr.io/o/x:1"))
    }

    @Test func aRunAnswersEveryReference() async throws {
        let (daemon, runner) = try daemon { _ in ok(#"{"Descriptor":{"digest":"\#(d1)"}}"#) }
        defer { daemon.stop() }
        let refs = ["a", "b", "c"].compactMap(ImageRef.parse)
        let answers = await runner.check(refs, now: now)
        #expect(Set(answers.keys) == Set(refs.map(\.normalized)))
        #expect(daemon.seen.count == 3)
    }

    // MARK: - Pull

    @Test func aPullPostsTheRepositoryAndTheTag() async throws {
        let (daemon, runner) = try daemon { _ in
            .init(
                chunks: [
                    line(#"{"status":"Pulling from library/nginx","id":"latest"}"#),
                    line(#"{"status":"Status: Downloaded newer image for nginx:latest"}"#),
                ])
        }
        defer { daemon.stop() }
        let result = await runner.pull(try #require(ImageRef.parse("nginx")), platform: nil)
        #expect(result == .pulled)
        #expect(daemon.seen == ["POST /images/create?fromImage=docker%2Eio%2Flibrary%2Fnginx&tag=latest HTTP/1.0"])
        #expect(daemon.seenRequests.first?.headers["x-registry-auth"] == nil)
    }

    @Test func aPullOfAnotherArchitectureNamesThePlatform() async throws {
        let (daemon, runner) = try daemon { _ in .init(chunks: [line(#"{"status":"Status: Image is up to date"}"#)]) }
        defer { daemon.stop() }
        let result = await runner.pull(try #require(ImageRef.parse("ghcr.io/o/a:1")), platform: "linux/arm/v7")
        #expect(result == .pulled)
        #expect(
            daemon.seen == ["POST /images/create?fromImage=ghcr%2Eio%2Fo%2Fa&tag=1&platform=linux%2Farm%2Fv7 HTTP/1.0"])
    }

    @Test func anErrorLineInAnOKStreamIsAFailure() async throws {
        let (daemon, runner) = try daemon { _ in
            .init(
                chunks: [
                    line(#"{"status":"Pulling from o/a"}"#),
                    line(
                        #"{"errorDetail":{"message":"unauthorized: authentication required"},"error":"unauthorized: authentication required"}"#
                    ),
                ])
        }
        defer { daemon.stop() }
        let result = await runner.pull(try #require(ImageRef.parse("o/a")), platform: nil)
        #expect(result == .failed(.signInNeeded, message: "unauthorized: authentication required"))
    }

    @Test func aStreamThatEndsWithoutAStatusLineIsAFailure() async throws {
        let (daemon, runner) = try daemon { _ in .init(chunks: [line(#"{"status":"Pulling from o/a"}"#)]) }
        defer { daemon.stop() }
        let result = await runner.pull(try #require(ImageRef.parse("o/a")), platform: nil)
        #expect(result == .failed(.other, message: "the pull ended early"))
    }

    @Test func anErrorStatusWithoutAMessageIsAFailureWithTheStatus() async throws {
        let (daemon, runner) = try daemon { _ in .init(status: 404, body: Data("not json".utf8)) }
        defer { daemon.stop() }
        let result = await runner.pull(try #require(ImageRef.parse("o/a")), platform: nil)
        #expect(result == .failed(.notFound, message: "HTTP 404"))
    }

    @Test func theMessageOfAnErrorStatusDecidesTheFailureKind() async throws {
        let message = "pull access denied for o/a, repository does not exist or may require 'docker login'"
        let (daemon, runner) = try daemon { _ in
            .init(status: 404, body: Data(#"{"message":"\#(message)"}"#.utf8))
        }
        defer { daemon.stop() }
        let result = await runner.pull(try #require(ImageRef.parse("o/a")), platform: nil)
        #expect(result == .failed(.signInNeeded, message: message))

        let (limited, runner2) = try self.daemon { _ in
            .init(status: 429, chunks: [line(#"{"message":"toomanyrequests: You have reached your pull rate limit"}"#)])
        }
        defer { limited.stop() }
        let result2 = await runner2.pull(try #require(ImageRef.parse("o/a")), platform: nil)
        #expect(result2 == .failed(.rateLimited, message: "toomanyrequests: You have reached your pull rate limit"))
    }

    @Test func aLongErrorBodyIsCutAtFourKilobytes() async throws {
        let filler = String(repeating: "x", count: 20_000)
        let (daemon, _) = try daemon { _ in .init(status: 500, body: Data(#"{"message":"\#(filler)"}"#.utf8)) }
        defer { daemon.stop() }
        let ended = Box<StreamHandle?>(nil)
        _ = DockerAPI(socketPath: daemon.path).stream("/images/create?fromImage=a", method: "POST", onLine: { _ in }) {
            handle in
            ended.mutate { $0 = handle }
        }
        #expect(await waitUntil { ended.value != nil })
        #expect(ended.value?.status == 500)
        #expect(ended.value?.errorBody?.count == DockerAPI.errorBodyLimit)
    }

    @Test func noDaemonIsUnreachable() async throws {
        let runner = ImageUpdateRunner(api: DockerAPI(socketPath: TestSocketPath.unique()))
        let result = await runner.pull(try #require(ImageRef.parse("o/a")), platform: nil)
        #expect(result == .failed(.unreachable, message: "the daemon does not answer"))
    }

    @Test func cancellingAPullStopsTheStream() async throws {
        let (daemon, runner) = try daemon { _ in
            .init(chunks: [line(#"{"status":"Pulling from o/a"}"#)], holdOpen: true)
        }
        defer { daemon.stop() }
        let ref = try #require(ImageRef.parse("o/a"))
        let task = Task { await runner.pull(ref, platform: nil) }
        #expect(await waitUntil { !daemon.seen.isEmpty })
        task.cancel()
        #expect(await task.value == .cancelled)
    }
}
