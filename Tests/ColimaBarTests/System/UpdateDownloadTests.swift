import Foundation
import Testing

@testable import ColimaBar

@Suite struct UpdateDownloadTests {
    private let host = "release-assets.githubusercontent.com"

    private func url() -> URL { URL(string: "https://\(host)/\(UUID().uuidString)/ColimaBar.zip")! }

    private func download(
        _ url: URL, size: Int, folder: TempFolder, progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) -> UpdateDownload {
        UpdateDownload(
            url: url, expectedSize: size, file: URL(fileURLWithPath: "\(folder.path)/ColimaBar.zip"),
            userAgent: "ColimaBar/test", configure: StubProtocol.useIt, progress: progress)
    }

    @Test func writesTheFileAndHashesIt() async throws {
        let tmp = try TempFolder()
        let chunks = (0..<5).map { Data(repeating: UInt8($0), count: 1000) }
        let u = url()
        StubProtocol.register(u, .body(status: 200, chunks: chunks))
        let out = try await download(u, size: 5000, folder: tmp).run()
        var d = ReleaseDigest()
        for c in chunks { d.update(c) }
        #expect(out.bytes == 5000)
        #expect(out.sha256 == d.hex())
        #expect(try Data(contentsOf: out.file).count == 5000)
    }

    @Test func reportsProgressUpToOne() async throws {
        let tmp = try TempFolder()
        let last = Box()
        let u = url()
        StubProtocol.register(u, .body(status: 200, chunks: [Data(count: 2000), Data(count: 2000)]))
        _ = try await download(u, size: 4000, folder: tmp) { last.set($0) }.run()
        #expect(last.value == 1)
    }

    @Test func stopsWhenTheFileIsLargerThanListed() async throws {
        let tmp = try TempFolder()
        let u = url()
        StubProtocol.register(u, .body(status: 200, chunks: [Data(count: 3000), Data(count: 3000)]))
        await #expect(throws: UpdateError.sizeMismatch) { try await download(u, size: 4000, folder: tmp).run() }
        #expect(!FileManager.default.fileExists(atPath: "\(tmp.path)/ColimaBar.zip"))
    }

    @Test func aShortFileReachesTheVerifierWhichRefusesIt() async throws {
        let tmp = try TempFolder()
        let u = url()
        StubProtocol.register(u, .body(status: 200, chunks: [Data(count: 3000)]))
        let out = try await download(u, size: 4000, folder: tmp).run()
        #expect(out.bytes == 3000)
        #expect(throws: UpdateError.sizeMismatch) {
            try UpdateVerifier.checkDownload(
                bytes: out.bytes, sha256: out.sha256, asset: ReleaseInfo.Asset(size: 4000, sha256: out.sha256))
        }
    }

    @Test func refusesAnotherStatus() async throws {
        let tmp = try TempFolder()
        let u = url()
        StubProtocol.register(u, .body(status: 404, chunks: [Data("not found".utf8)]))
        await #expect(throws: UpdateError.self) { try await download(u, size: 100, folder: tmp).run() }
        #expect(!FileManager.default.fileExists(atPath: "\(tmp.path)/ColimaBar.zip"))
    }

    @Test func followsARedirectToAnAssetHost() async throws {
        let tmp = try TempFolder()
        let target = url()
        let u = URL(string: "https://github.com/imohitkr/colima-bar/releases/download/v0.9.1/\(UUID().uuidString).zip")!
        StubProtocol.register(u, .redirect(to: target))
        StubProtocol.register(target, .body(status: 200, chunks: [Data(count: 500)]))
        let out = try await download(u, size: 500, folder: tmp).run()
        #expect(out.bytes == 500)
    }

    @Test func refusesARedirectToAnotherHost() async throws {
        let tmp = try TempFolder()
        let evil = URL(string: "https://evil.example/\(UUID().uuidString)/ColimaBar.zip")!
        let u = url()
        StubProtocol.register(u, .redirect(to: evil))
        StubProtocol.register(evil, .body(status: 200, chunks: [Data(count: 500)]))
        await #expect(throws: UpdateError.self) { try await download(u, size: 500, folder: tmp).run() }
        #expect(!FileManager.default.fileExists(atPath: "\(tmp.path)/ColimaBar.zip"))
    }

    @Test func refusesARedirectToHttp() async throws {
        let tmp = try TempFolder()
        let plain = URL(string: "http://\(host)/\(UUID().uuidString)/ColimaBar.zip")!
        let u = url()
        StubProtocol.register(u, .redirect(to: plain))
        StubProtocol.register(plain, .body(status: 200, chunks: [Data(count: 500)]))
        await #expect(throws: UpdateError.self) { try await download(u, size: 500, folder: tmp).run() }
    }

    @Test func aCancelBeforeTheStartEndsAsCancelled() async throws {
        let tmp = try TempFolder()
        let u = url()
        StubProtocol.register(u, .body(status: 200, chunks: [Data(count: 500)]))
        let d = download(u, size: 500, folder: tmp)
        d.cancel()
        await #expect(throws: UpdateError.cancelled) { try await d.run() }
    }

    @Test func stopsAnUnsizedStreamThatPassesTheListedSize() async throws {
        // No Content-Length: only the byte count can stop it.
        let tmp = try TempFolder()
        let u = url()
        StubProtocol.register(u, .unsizedBody(chunks: [Data(count: 3000), Data(count: 3000)]))
        await #expect(throws: UpdateError.sizeMismatch) { try await download(u, size: 4000, folder: tmp).run() }
        #expect(!FileManager.default.fileExists(atPath: "\(tmp.path)/ColimaBar.zip"))
    }

    @Test func aCancelDuringTheTransferRemovesThePartialFile() async throws {
        let tmp = try TempFolder()
        let u = url()
        let file = "\(tmp.path)/ColimaBar.zip"
        StubProtocol.register(u, .stall(first: Data(count: 1000)))
        let d = download(u, size: 4000, folder: tmp)
        let task = Task { try await d.run() }
        // The first chunk is on disk.
        let started = await waitUntil {
            ((try? FileManager.default.attributesOfItem(atPath: file))?[.size] as? Int ?? 0) > 0
        }
        #expect(started)
        task.cancel()
        await #expect(throws: UpdateError.cancelled) { try await task.value }
        #expect(!FileManager.default.fileExists(atPath: file))
    }

    @Test func aFullDiskIsNotEnoughSpaceNotANetworkError() {
        #expect(UpdateDownload.writeFailure(NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))) == .notEnoughSpace)
        #expect(
            UpdateDownload.writeFailure(
                NSError(domain: NSCocoaErrorDomain, code: CocoaError.fileWriteOutOfSpace.rawValue))
                == .notEnoughSpace)
        guard case .network(let why) = UpdateDownload.writeFailure(NSError(domain: NSPOSIXErrorDomain, code: Int(EIO)))
        else {
            Issue.record("expected .network")
            return
        }
        #expect(why.contains("could not be written"))
    }

    /// A thread-safe holder of the last progress value.
    private final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var v = 0.0
        func set(_ x: Double) { lock.withLock { v = x } }
        var value: Double { lock.withLock { v } }
    }
}
