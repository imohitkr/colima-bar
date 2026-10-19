import Foundation
import Testing

@testable import ColimaBar

@Suite struct DockerAPIUploadTests {
    private func file(_ folder: TempFolder, _ data: Data) throws -> Int32 {
        let path = folder.path + "/f.bin"
        try data.write(to: URL(fileURLWithPath: path))
        return open(path, O_RDONLY)
    }

    @Test func uploadSendsTheChosenRangeWithItsLengthAndType() async throws {
        let socket = TestSocketPath.unique()
        let daemon = FakeDaemon(path: socket) { _ in .init(status: 200, body: Data("done".utf8)) }
        try daemon.start()
        defer { daemon.stop() }
        let folder = try TempFolder()
        let fd = try file(folder, Data("HEADERBODYDATA".utf8))
        defer { close(fd) }
        let progress = ProgressBox()
        let up = DockerAPI(socketPath: socket).upload(
            "PUT", "/containers/c1/archive?path=/", fd: fd, offset: 6, length: 8, contentType: "application/x-tar",
            onProgress: { progress.set($0) })
        let reply = await up.response.value
        #expect(reply?.status == 200 && reply?.body == Data("done".utf8))
        let request = try #require(daemon.seenRequests.first)
        #expect(request.line == "PUT /containers/c1/archive?path=/ HTTP/1.0")
        #expect(request.body == Data("BODYDATA".utf8))
        #expect(request.headers["content-length"] == "8")
        #expect(request.headers["content-type"] == "application/x-tar")
        #expect(progress.value == 8)
    }

    @Test func uploadSendsABodyOfSeveralChunks() async throws {
        let socket = TestSocketPath.unique()
        let daemon = FakeDaemon(path: socket) { _ in .init(status: 200) }
        try daemon.start()
        defer { daemon.stop() }
        let folder = try TempFolder()
        let data = Data((0..<300_000).map { UInt8($0 % 251) })
        let fd = try file(folder, data)
        defer { close(fd) }
        let up = DockerAPI(socketPath: socket).upload(
            "PUT", "/x", fd: fd, offset: 0, length: Int64(data.count), contentType: "application/x-tar",
            onProgress: { _ in })
        _ = await up.response.value
        #expect(daemon.seenRequests.first?.body == data)
    }

    @Test func uploadGivesAnErrorReplyOfTheDaemon() async throws {
        let socket = TestSocketPath.unique()
        let daemon = FakeDaemon(path: socket) { _ in .init(status: 500, body: Data(#"{"message":"no space"}"#.utf8)) }
        try daemon.start()
        defer { daemon.stop() }
        let folder = try TempFolder()
        let fd = try file(folder, Data("abc".utf8))
        defer { close(fd) }
        let up = DockerAPI(socketPath: socket).upload(
            "PUT", "/x", fd: fd, offset: 0, length: 3, contentType: "application/x-tar", onProgress: { _ in })
        let reply = await up.response.value
        #expect(reply?.status == 500 && reply?.ok == false)
    }

    @Test func uploadFailsWhenTheFileIsShorterThanTheLength() async throws {
        let socket = TestSocketPath.unique()
        let daemon = FakeDaemon(path: socket) { _ in .init(status: 200) }
        try daemon.start()
        defer { daemon.stop() }
        let folder = try TempFolder()
        let fd = try file(folder, Data("abc".utf8))
        defer { close(fd) }
        let up = DockerAPI(socketPath: socket).upload(
            "PUT", "/x", fd: fd, offset: 0, length: 100, contentType: "application/x-tar", onProgress: { _ in })
        #expect(await up.response.value == nil)
    }

    @Test func uploadFailsWhenNothingListens() async throws {
        let folder = try TempFolder()
        let fd = try file(folder, Data("abc".utf8))
        defer { close(fd) }
        let up = DockerAPI(socketPath: TestSocketPath.unique()).upload(
            "PUT", "/x", fd: fd, offset: 0, length: 3, contentType: "application/x-tar", onProgress: { _ in })
        #expect(await up.response.value == nil)
    }

    @Test func cancelStopsAnUploadThatTheDaemonDoesNotRead() async throws {
        let socket = TestSocketPath.unique()
        let daemon = StalledDaemon(path: socket)
        try daemon.start()
        defer { daemon.stop() }
        let folder = try TempFolder()
        let fd = try file(folder, Data(repeating: 7, count: 32 << 20))
        defer { close(fd) }
        let progress = ProgressBox()
        let up = DockerAPI(socketPath: socket).upload(
            "PUT", "/x", fd: fd, offset: 0, length: 32 << 20, contentType: "application/x-tar",
            onProgress: { progress.set($0) })
        #expect(await waitUntil { daemon.sawHead })
        up.handle.cancel()
        #expect(await up.response.value == nil)
        #expect(progress.value < 32 << 20)
    }
}

/// The last progress value, from the sending thread.
/// `@unchecked Sendable`: `lock` guards `last`.
private final class ProgressBox: @unchecked Sendable {
    private let lock = NSLock()
    private var last: Int64 = 0
    func set(_ v: Int64) { lock.withLock { last = v } }
    var value: Int64 { lock.withLock { last } }
}

/// Accepts a connection, reads the request head and then reads nothing more,
/// so the socket buffers of an upload fill up.
/// `@unchecked Sendable`: `lock` guards `head`.
private final class StalledDaemon: @unchecked Sendable {
    let path: String
    private let loop: AcceptLoop
    private let lock = NSLock()
    private var head = false

    init(path: String) {
        self.path = path
        loop = AcceptLoop(path: path)
    }

    var sawHead: Bool { lock.withLock { head } }

    func start() throws {
        try loop.start { [self] c in
            // The loop thread must stay free for `stop()`: wait on a thread of its own.
            Thread.detachNewThread { [self] in
                defer { close(c) }
                var byte = [UInt8](repeating: 0, count: 1)
                var text = Data()
                while text.range(of: Data("\r\n\r\n".utf8)) == nil {
                    guard readable(c), read(c, &byte, 1) > 0 else { return }
                    text.append(byte, count: 1)
                }
                lock.withLock { head = true }
                // It reads nothing more: the buffers of the upload must fill up.
                while !loop.isStopped { usleep(10_000) }
            }
        }
    }

    func stop() { loop.stop() }

    /// Waits up to 20 ms for data. False if the daemon stopped.
    private func readable(_ c: Int32) -> Bool {
        while !loop.isStopped {
            var p = pollfd(fd: c, events: Int16(POLLIN), revents: 0)
            if poll(&p, 1, 20) > 0 { return true }
        }
        return false
    }
}
