import Foundation
import Testing

@testable import ColimaBar

@Suite struct DockerAPIRequestTests {
    @Test func aPostWithJSONSendsTheBodyAndItsType() async throws {
        let socket = TestSocketPath.unique()
        let daemon = FakeDaemon(path: socket) { _ in .init(status: 201, body: Data("{}".utf8)) }
        try daemon.start()
        defer { daemon.stop() }
        let reply = await DockerAPI(socketPath: socket).post("/volumes/create", json: Data(#"{"Name":"a"}"#.utf8))
        #expect(reply?.status == 201)
        let request = try #require(daemon.seenRequests.first)
        #expect(request.body == Data(#"{"Name":"a"}"#.utf8))
        #expect(request.headers["content-type"] == "application/json" && request.headers["content-length"] == "12")
    }

    @Test func aRequestWithoutABodyKeepsItsZeroLength() async throws {
        let socket = TestSocketPath.unique()
        let daemon = FakeDaemon(path: socket) { _ in .init(status: 204) }
        try daemon.start()
        defer { daemon.stop() }
        _ = await DockerAPI(socketPath: socket).request("DELETE", "/containers/c?force=1")
        let request = try #require(daemon.seenRequests.first)
        #expect(request.headers["content-length"] == "0" && request.body.isEmpty)
    }

    @Test func aGetSendsNoContentLength() async throws {
        let socket = TestSocketPath.unique()
        let daemon = FakeDaemon(path: socket)
        try daemon.start()
        defer { daemon.stop() }
        _ = await DockerAPI(socketPath: socket).get("/info")
        #expect(daemon.seenRequests.first?.headers["content-length"] == nil)
    }

    @Test func aStreamCanUseAPostAndGetsItsLines() async throws {
        let socket = TestSocketPath.unique()
        let daemon = FakeDaemon(path: socket) { _ in
            .init(chunks: [Data("{\"a\":1}\n{\"a\"".utf8), Data(":2}\n".utf8)])
        }
        try daemon.start()
        defer { daemon.stop() }
        let lines = Box<[String]>([])
        let ended = Box(false)
        _ = DockerAPI(socketPath: socket).stream(
            "/images/create?fromImage=x", method: "POST",
            onLine: { data in lines.mutate { $0.append(String(decoding: data, as: UTF8.self)) } },
            onEnd: { _ in ended.mutate { $0 = true } })
        #expect(await waitUntil { ended.value })
        #expect(lines.value == [#"{"a":1}"#, #"{"a":2}"#])
        let request = try #require(daemon.seenRequests.first)
        #expect(request.line == "POST /images/create?fromImage=x HTTP/1.0")
        #expect(request.headers["content-length"] == "0")
    }
}
