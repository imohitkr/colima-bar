import Darwin
import Foundation
import Testing

@testable import ColimaBar

/// A thread-safe list of the profiles that a wake started.
private final class WakeLog: @unchecked Sendable {
    private let lock = NSLock()
    private var names: [String] = []
    func add(_ n: String) { lock.withLock { names.append(n) } }
    var all: [String] { lock.withLock { names } }
}

@Suite(.serialized) @MainActor struct ProfileProxiesTests {
    private let request = "GET /v1.54/containers/json HTTP/1.1\r\nHost: docker\r\n\r\n"

    /// Two profiles "a" and "b", each with its own fake daemon that is down.
    /// A wake for a profile starts that profile's daemon.
    private func withTwoProfiles(
        _ body: (ProfileProxies, [String: FakeDaemon], WakeLog, String) async throws -> Void
    ) async throws {
        let dir = TestSocketPath.uniqueDir()
        let up = ["a": TestSocketPath.unique(), "b": TestSocketPath.unique()]
        let daemons = up.mapValues { FakeDaemon(path: $0) }
        let woke = WakeLog()
        let proxies = ProfileProxies(dir: dir, upstream: { up[$0] ?? "/nonexistent" })
        proxies.apiVersion = "1.54"
        proxies.wake = { name in
            woke.add(name)
            try? daemons[name]?.start()  // that profile's "Colima" comes up
            return true
        }
        defer {
            proxies.shutdown()
            for d in daemons.values { d.stop() }
            try? FileManager.default.removeItem(atPath: dir)
        }
        try await body(proxies, daemons, woke, dir)
    }

    /// roundTrip blocks, so it runs off the main actor.
    nonisolated private func send(_ path: String, _ request: String, until: String? = nil) async -> String {
        await Task.detached { roundTrip(path, request, until: until) }.value
    }

    @Test func eachSocketWakesItsOwnProfile() async throws {
        try await withTwoProfiles { proxies, daemons, woke, _ in
            proxies.sync(wanted: ["a", "b"])
            proxies.setListening(true)
            let a = try #require(proxies.path(for: "a"))
            let b = try #require(proxies.path(for: "b"))

            let ra = await send(a, request)
            #expect(ra.hasSuffix("hello"))
            #expect(woke.all == ["a"])
            #expect(daemons["a"]?.seen == ["GET /v1.54/containers/json HTTP/1.1"])
            #expect(daemons["b"]?.seen == [])

            let rb = await send(b, request)
            #expect(rb.hasSuffix("hello"))
            #expect(woke.all == ["a", "b"])
            #expect(daemons["b"]?.seen == ["GET /v1.54/containers/json HTTP/1.1"])
        }
    }

    @Test func aPingDoesNotWakeAProfile() async throws {
        try await withTwoProfiles { proxies, _, woke, _ in
            proxies.sync(wanted: ["a"])
            proxies.setListening(true)
            let a = try #require(proxies.path(for: "a"))
            // The proxy keeps the connection open after a ping.
            let r = await send(a, "HEAD /_ping HTTP/1.1\r\nHost: docker\r\n\r\n", until: "\r\n\r\n")
            #expect(r.hasPrefix("HTTP/1.1 200 OK"))
            #expect(woke.all.isEmpty)
        }
    }

    @Test func proxiesFollowTheProfiles() async throws {
        try await withTwoProfiles { proxies, _, _, dir in
            proxies.sync(wanted: ["a", "b"])
            proxies.setListening(true)
            #expect(proxies.names == ["a", "b"])
            #expect(FileManager.default.fileExists(atPath: "\(dir)/b.sock"))

            proxies.sync(wanted: ["a"])
            #expect(proxies.names == ["a"])
            #expect(!FileManager.default.fileExists(atPath: "\(dir)/b.sock"))

            // A VM action runs for "a" (it is deleted for a short time): keep it.
            proxies.sync(wanted: [], keep: ["a"])
            #expect(proxies.names == ["a"])
        }
    }

    @Test func oldSocketsOfGoneProfilesAreRemoved() async throws {
        try await withTwoProfiles { proxies, _, _, dir in
            let fm = FileManager.default
            symlink("/nonexistent/docker.sock", "\(dir)/gone.sock")
            fm.createFile(atPath: "\(dir)/a.sock.tmp", contents: nil)
            fm.createFile(atPath: "\(dir)/notes.txt", contents: nil)
            proxies.sync(wanted: ["a"])
            let files = Set((try? fm.contentsOfDirectory(atPath: dir)) ?? [])
            #expect(files == ["a.sock", "notes.txt"])
        }
    }

    @Test func eachSocketLinksToItsProfileWhenStopped() async throws {
        try await withTwoProfiles { proxies, daemons, _, dir in
            proxies.sync(wanted: ["a", "b"])
            // Auto-start is off: each path is a link to its profile's socket.
            #expect(readLink("\(dir)/a.sock") == daemons["a"]?.path)
            proxies.setListening(true)
            #expect(readLink("\(dir)/a.sock") == nil)  // a real socket now
            proxies.shutdown()  // quit
            #expect(readLink("\(dir)/a.sock") == daemons["a"]?.path)
            #expect(readLink("\(dir)/b.sock") == daemons["b"]?.path)
        }
    }

    @Test func aNameThatIsTooLongGetsNoProxy() async throws {
        try await withTwoProfiles { proxies, _, _, _ in
            let long = String(repeating: "x", count: 120)
            proxies.sync(wanted: ["a", long])
            #expect(proxies.names == ["a"])
            #expect(proxies.activeTransfers(long) == 0)
        }
    }

    private func readLink(_ path: String) -> String? {
        try? FileManager.default.destinationOfSymbolicLink(atPath: path)
    }
}
