import Foundation
import Testing

@testable import ColimaBar

/// The keeper against a fake daemon. Containers named "rm-*" have
/// AutoRemove set, "plain-*" do not, and all others do not exist.
@Suite @MainActor struct RemovedLogKeeperTests {
    /// The log lines that the fake daemon sends for a container.
    nonisolated private static func logText(_ id: String) -> [String] {
        (1...10).map { "\(id) line \($0)" }
    }

    nonisolated private static func reply(_ requestLine: String) -> (status: Int, body: Data) {
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return (400, Data()) }
        let path = parts[1]
        guard path.hasPrefix("/containers/") else { return (404, Data()) }
        let rest = path.dropFirst("/containers/".count)
        let id = String(rest.prefix { $0 != "/" })
        let known = id.hasPrefix("rm-") || id.hasPrefix("plain-")
        guard known else { return (404, Data(#"{"message":"No such container"}"#.utf8)) }
        if rest.hasSuffix("/json") {
            let auto = id.hasPrefix("rm-")
            return (200, Data(#"{"Id":"\#(id)","Config":{"Tty":false},"HostConfig":{"AutoRemove":\#(auto)}}"#.utf8))
        }
        if rest.contains("/logs?") {
            var body = Data()
            for (i, t) in logText(id).enumerated() {
                body += LogFrame.make(i == 9 ? 2 : 1, "2026-10-07T10:00:0\(i).000000000Z \(t)\n")
            }
            return (200, body)
        }
        return (404, Data())
    }

    /// A running fake daemon and a keeper that uses it.
    @MainActor private struct Rig {
        let daemon: FakeDaemon
        let keeper: RemovedLogKeeper
        let clock: TestClock
        let changes: ChangeLog

        func stop() {
            keeper.isEnabled = false
            daemon.stop()
        }

        /// Requests for the logs of `id`.
        func logRequests(_ id: String) -> [String] {
            daemon.seen.filter { $0.contains("/containers/\(id)/logs?") }
        }

        /// Sends a start event and waits until the stream of `id` delivered
        /// all its lines and ended.
        func startAndDrain(_ id: String) async -> Bool {
            keeper.event(action: "start", id: id, attributes: ["name": id])
            return await waitUntil { !logRequests(id).isEmpty && keeper.openStreams == 0 }
        }
    }

    /// Each change of the kept set, in order.
    @MainActor final class ChangeLog {
        var sets: [Set<String>] = []
    }

    private func rig(
        maxContainers: Int = 50, maxLines: Int = 500, maxBytes: Int = RemovedLogKeeper.maxBytes
    ) throws -> Rig {
        let path = TestSocketPath.unique()
        let daemon = FakeDaemon(path: path, reply: Self.reply)
        try daemon.start()
        let clock = TestClock()
        let keeper = RemovedLogKeeper(
            api: DockerAPI(socketPath: path), maxContainers: maxContainers, maxLines: maxLines,
            maxBytes: maxBytes, now: { clock.now })
        let r = Rig(daemon: daemon, keeper: keeper, clock: clock, changes: ChangeLog())
        keeper.onChange = { [changes = r.changes] in changes.sets.append($0) }
        keeper.isEnabled = true
        return r
    }

    @Test func offOpensNoStreams() throws {
        let r = try rig()
        defer { r.stop() }
        r.keeper.isEnabled = false
        r.keeper.event(action: "start", id: "rm-1", attributes: [:])
        #expect(r.keeper.bufferedCount == 0)
        #expect(r.daemon.seen.isEmpty)
    }

    @Test func streamsOnlyAutoRemoveContainers() async throws {
        let r = try rig()
        defer { r.stop() }
        r.keeper.event(action: "start", id: "plain-1", attributes: [:])
        #expect(await r.startAndDrain("rm-1"))
        #expect(await waitUntil { r.keeper.bufferedCount == 1 })
        #expect(r.logRequests("plain-1").isEmpty)
        let q = try #require(r.logRequests("rm-1").first)
        for part in ["follow=1", "stdout=1", "stderr=1", "timestamps=1", "tail=\(RemovedLogKeeper.initialTail)"] {
            #expect(q.contains(part), "\(part)")
        }
    }

    @Test func keepsTheLinesOfAFailedContainer() async throws {
        let r = try rig()
        defer { r.stop() }
        #expect(await r.startAndDrain("rm-1"))
        #expect(r.keeper.saved("rm-1") == nil)  // still running: nothing to show
        r.keeper.event(action: "die", id: "rm-1", attributes: ["exitCode": "1"])
        let saved = try #require(r.keeper.saved("rm-1"))
        #expect(saved.map(\.text) == Self.logText("rm-1"))
        #expect(saved.last?.isStderr == true)
        #expect(r.keeper.keptIDs == ["rm-1"])
        #expect(r.changes.sets == [["rm-1"]])
        // Docker removes the container: the lines stay.
        r.keeper.event(action: "destroy", id: "rm-1", attributes: [:])
        #expect(r.keeper.saved("rm-1") != nil)
    }

    @Test func dropsTheLinesOfACleanExit() async throws {
        let r = try rig()
        defer { r.stop() }
        #expect(await r.startAndDrain("rm-1"))
        r.keeper.event(action: "die", id: "rm-1", attributes: ["exitCode": "0"])
        #expect(r.keeper.saved("rm-1") == nil)
        #expect(r.keeper.bufferedCount == 0)
        #expect(r.changes.sets.isEmpty)
    }

    @Test func ignoredExitCodesDropTheLines() async throws {
        let r = try rig()
        defer { r.stop() }
        for code in ["130", "137", "143"] {
            let id = "rm-\(code)"
            #expect(await r.startAndDrain(id))
            r.keeper.event(action: "die", id: id, attributes: ["exitCode": code])
            #expect(r.keeper.saved(id) == nil, "\(code)")
        }
        // No exit code is no failure, as for the crash alert.
        #expect(await r.startAndDrain("rm-none"))
        r.keeper.event(action: "die", id: "rm-none", attributes: [:])
        #expect(r.keeper.bufferedCount == 0)
    }

    @Test func outOfMemoryKillKeepsTheLines() async throws {
        let r = try rig()
        defer { r.stop() }
        #expect(await r.startAndDrain("rm-1"))
        r.keeper.event(action: "oom", id: "rm-1", attributes: [:])
        r.keeper.event(action: "die", id: "rm-1", attributes: ["exitCode": "137"])
        #expect(r.keeper.saved("rm-1")?.count == 10)
    }

    @Test func keptLinesExpireAfterTheWindow() async throws {
        let r = try rig()
        defer { r.stop() }
        #expect(await r.startAndDrain("rm-1"))
        r.keeper.event(action: "die", id: "rm-1", attributes: ["exitCode": "2"])
        r.clock.advance(RemovedLogKeeper.keepWindow - 1)
        r.keeper.purgeExpired()
        #expect(r.keeper.saved("rm-1") != nil)
        r.clock.advance(2)
        r.keeper.purgeExpired()
        #expect(r.keeper.saved("rm-1") == nil)
        #expect(r.keeper.bufferedCount == 0)
        #expect(r.changes.sets == [["rm-1"], []])
    }

    @Test func destroyWithoutAFailureDropsTheLines() async throws {
        let r = try rig()
        defer { r.stop() }
        #expect(await r.startAndDrain("rm-1"))
        r.keeper.event(action: "destroy", id: "rm-1", attributes: [:])
        #expect(r.keeper.bufferedCount == 0)
    }

    @Test func turningOffAndResetDropEverything() async throws {
        let r = try rig()
        defer { r.stop() }
        #expect(await r.startAndDrain("rm-1"))
        r.keeper.event(action: "die", id: "rm-1", attributes: ["exitCode": "1"])
        r.keeper.isEnabled = false
        #expect(r.keeper.saved("rm-1") == nil)
        #expect(r.keeper.bufferedCount == 0)
        #expect(r.keeper.keptIDs.isEmpty)

        // A profile switch resets the keeper.
        r.keeper.isEnabled = true
        #expect(await r.startAndDrain("rm-2"))
        r.keeper.event(action: "die", id: "rm-2", attributes: ["exitCode": "1"])
        r.keeper.reset(api: DockerAPI(socketPath: r.daemon.path))
        #expect(r.keeper.bufferedCount == 0)
        #expect(r.changes.sets == [["rm-1"], [], ["rm-2"], []])
    }

    @Test func skipsTestcontainers() throws {
        let r = try rig()
        defer { r.stop() }
        r.keeper.event(action: "start", id: "rm-1", attributes: ["org.testcontainers": "true"])
        #expect(r.keeper.bufferedCount == 0)
        #expect(r.daemon.seen.isEmpty)
    }

    @Test func capsTheContainersAndEvictsTheOldestKeptFirst() async throws {
        let r = try rig(maxContainers: 2)
        defer { r.stop() }
        #expect(await r.startAndDrain("rm-1"))
        #expect(await r.startAndDrain("rm-2"))
        // Full and nothing is kept: a new container gets no buffer.
        r.keeper.event(action: "start", id: "rm-3", attributes: [:])
        #expect(r.keeper.bufferedCount == 2)
        #expect(!r.daemon.seen.contains { $0.contains("/containers/rm-3/") })

        r.keeper.event(action: "die", id: "rm-1", attributes: ["exitCode": "1"])
        r.clock.advance(1)
        r.keeper.event(action: "die", id: "rm-2", attributes: ["exitCode": "1"])
        // Full: the oldest kept buffer (rm-1) makes room.
        #expect(await r.startAndDrain("rm-4"))
        #expect(r.keeper.saved("rm-1") == nil)
        #expect(r.keeper.saved("rm-2") != nil)
        #expect(r.keeper.bufferedCount == 2)
    }

    @Test func eachContainerGetsAnEqualShareOfTheBytes() {
        #expect(RemovedLogKeeper.maxBytes / RemovedLogKeeper.maxContainers == 128 << 10)
    }

    @Test func capsTheLinesAndBytesOfEachContainer() async throws {
        // 2 containers share 240 bytes: 120 bytes each. A frame with its
        // header and timestamp is about 52 bytes, so the 2 newest fit.
        let r = try rig(maxContainers: 2, maxBytes: 240)
        defer { r.stop() }
        #expect(await r.startAndDrain("rm-1"))
        r.keeper.event(action: "die", id: "rm-1", attributes: ["exitCode": "1"])
        let saved = try #require(r.keeper.saved("rm-1"))
        #expect(saved.map(\.text) == Array(Self.logText("rm-1").suffix(2)))

        let few = try rig(maxLines: 3)
        defer { few.stop() }
        #expect(await few.startAndDrain("rm-1"))
        few.keeper.event(action: "die", id: "rm-1", attributes: ["exitCode": "1"])
        #expect(few.keeper.saved("rm-1")?.map(\.text) == Array(Self.logText("rm-1").suffix(3)))
    }
}
