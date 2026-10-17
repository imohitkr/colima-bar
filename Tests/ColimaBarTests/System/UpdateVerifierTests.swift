import Foundation
import Testing

@testable import ColimaBar

@Suite struct UpdateVerifierTests {
    private let digest = String(repeating: "ab", count: 32)

    // MARK: plist rules

    private func plist(
        id: String = "com.imohitkr.ColimaBar", exe: String = "ColimaBar", version: String = "0.9.1"
    ) -> [String: Any] {
        ["CFBundleIdentifier": id, "CFBundleExecutable": exe, "CFBundleShortVersionString": version]
    }

    @Test func aMatchingPlistHasNoProblem() {
        #expect(UpdateVerifier.plistProblem(plist(), tag: "v0.9.1", running: "0.9.0") == nil)
    }

    @Test func eachWrongPlistValueIsAProblem() {
        func problem(_ p: [String: Any]?, tag: String = "v0.9.1", running: String = "0.9.0") -> String? {
            UpdateVerifier.plistProblem(p, tag: tag, running: running)
        }
        #expect(problem(nil) != nil)
        #expect(problem(plist(id: "com.example.Other")) != nil)
        #expect(problem(plist(exe: "Other")) != nil)
        #expect(problem(plist(version: "0.9.2")) != nil)  // not the tag
        #expect(problem([:]) != nil)
        // Not newer than the running version: the same, or a downgrade.
        #expect(problem(plist(), running: "0.9.1") != nil)
        #expect(problem(plist(), running: "1.0.0") != nil)
    }

    // MARK: download

    @Test func checksTheSizeAndTheDigest() throws {
        let asset = ReleaseInfo.Asset(size: 100, sha256: digest)
        try UpdateVerifier.checkDownload(bytes: 100, sha256: digest, asset: asset)
        #expect(throws: UpdateError.sizeMismatch) {
            try UpdateVerifier.checkDownload(bytes: 99, sha256: digest, asset: asset)
        }
        #expect(throws: UpdateError.digestMismatch) {
            try UpdateVerifier.checkDownload(bytes: 100, sha256: String(repeating: "cd", count: 32), asset: asset)
        }
    }

    // MARK: unpack

    @Test func unpacksAZipWithOnlyTheApp() async throws {
        let tmp = try TempFolder()
        try await FakeBundle.make(in: tmp.path, sign: false)
        try await FakeBundle.zip(["ColimaBar.app"], in: tmp.path, to: "\(tmp.path)/ok.zip")
        let into = "\(tmp.path)/out"
        try FileManager.default.createDirectory(atPath: into, withIntermediateDirectories: true)
        let app = try await UpdateVerifier.unpack(
            zip: URL(fileURLWithPath: "\(tmp.path)/ok.zip"), into: URL(fileURLWithPath: into))
        #expect(app.lastPathComponent == "ColimaBar.app")
        #expect(FileManager.default.fileExists(atPath: app.appendingPathComponent("Contents/Info.plist").path))
    }

    @Test func refusesAZipWithTwoEntries() async throws {
        let tmp = try TempFolder()
        try await FakeBundle.make(in: tmp.path, sign: false)
        try Data("x".utf8).write(to: URL(fileURLWithPath: "\(tmp.path)/extra.txt"))
        try await FakeBundle.zip(["ColimaBar.app", "extra.txt"], in: tmp.path, to: "\(tmp.path)/two.zip")
        let into = "\(tmp.path)/out"
        try FileManager.default.createDirectory(atPath: into, withIntermediateDirectories: true)
        await #expect(throws: UpdateError.self) {
            try await UpdateVerifier.unpack(
                zip: URL(fileURLWithPath: "\(tmp.path)/two.zip"), into: URL(fileURLWithPath: into))
        }
    }

    @Test func refusesAZipWithAnotherAppName() async throws {
        let tmp = try TempFolder()
        try await FakeBundle.make(in: tmp.path, name: "Other.app", sign: false)
        try await FakeBundle.zip(["Other.app"], in: tmp.path, to: "\(tmp.path)/other.zip")
        let into = "\(tmp.path)/out"
        try FileManager.default.createDirectory(atPath: into, withIntermediateDirectories: true)
        await #expect(throws: UpdateError.self) {
            try await UpdateVerifier.unpack(
                zip: URL(fileURLWithPath: "\(tmp.path)/other.zip"), into: URL(fileURLWithPath: into))
        }
    }

    @Test func refusesAFileThatIsNotAZip() async throws {
        let tmp = try TempFolder()
        try Data("not a zip".utf8).write(to: URL(fileURLWithPath: "\(tmp.path)/bad.zip"))
        let into = "\(tmp.path)/out"
        try FileManager.default.createDirectory(atPath: into, withIntermediateDirectories: true)
        await #expect(throws: UpdateError.self) {
            try await UpdateVerifier.unpack(
                zip: URL(fileURLWithPath: "\(tmp.path)/bad.zip"), into: URL(fileURLWithPath: into))
        }
    }

    @Test func sumsTheSizeOfTheFiles() throws {
        let tmp = try TempFolder()
        try FileManager.default.createDirectory(atPath: "\(tmp.path)/a/b", withIntermediateDirectories: true)
        try Data(count: 1000).write(to: URL(fileURLWithPath: "\(tmp.path)/a/one"))
        try Data(count: 234).write(to: URL(fileURLWithPath: "\(tmp.path)/a/b/two"))
        #expect(UpdateVerifier.unpackedSize(of: URL(fileURLWithPath: "\(tmp.path)/a")) == 1234)
        #expect(UpdateVerifier.unpackedSize(of: URL(fileURLWithPath: "\(tmp.path)/missing")) == Int.max)
    }

    // MARK: signature and bundle

    @Test func acceptsAValidSignatureWithTheRightIdentifier() async throws {
        let tmp = try TempFolder()
        let app = try await FakeBundle.make(in: tmp.path)
        try await UpdateVerifier.checkSignature(app)
    }

    @Test func refusesAnUnsignedBundle() async throws {
        let tmp = try TempFolder()
        let app = try await FakeBundle.make(in: tmp.path, sign: false)
        await #expect(throws: UpdateError.signatureInvalid) { try await UpdateVerifier.checkSignature(app) }
    }

    @Test func refusesABundleThatChangedAfterSigning() async throws {
        let tmp = try TempFolder()
        let app = try await FakeBundle.make(in: tmp.path)
        try Data("changed\n".utf8).write(to: app.appendingPathComponent("Contents/Resources/colima-ctl.sh"))
        await #expect(throws: UpdateError.signatureInvalid) { try await UpdateVerifier.checkSignature(app) }
    }

    @Test func refusesAnotherCodeIdentifier() async throws {
        let tmp = try TempFolder()
        let app = try await FakeBundle.make(in: tmp.path, signIdentifier: "com.example.Other")
        await #expect(throws: UpdateError.signatureInvalid) { try await UpdateVerifier.checkSignature(app) }
    }

    @Test func verifiesAWholeBundle() async throws {
        let tmp = try TempFolder()
        let app = try await FakeBundle.make(in: tmp.path, version: "0.9.1")
        try await UpdateVerifier.verifyBundle(app, tag: "v0.9.1", running: "0.9.0")
    }

    @Test func refusesABundleWithTheWrongVersion() async throws {
        let tmp = try TempFolder()
        let app = try await FakeBundle.make(in: tmp.path, version: "0.9.2")
        await #expect(throws: UpdateError.self) {
            try await UpdateVerifier.verifyBundle(app, tag: "v0.9.1", running: "0.9.0")
        }
    }

    @Test func refusesABundleWithoutTheScript() async throws {
        let tmp = try TempFolder()
        let app = try await FakeBundle.make(in: tmp.path, withScript: false)
        await #expect(throws: UpdateError.self) {
            try await UpdateVerifier.verifyBundle(app, tag: "v0.9.1", running: "0.9.0")
        }
    }

    @Test func removesTheQuarantineFlagFromTheUnpackedCopy() async throws {
        let tmp = try TempFolder()
        let app = try await FakeBundle.make(in: tmp.path)
        let flag = "0081;00000000;Test;"
        let set = await Shell.run(["/usr/bin/xattr", "-w", "com.apple.quarantine", flag, app.path])
        #expect(set.ok)
        try await UpdateVerifier.verifyBundle(app, tag: "v0.9.1", running: "0.9.0")
        let read = await Shell.run(["/usr/bin/xattr", app.path])
        #expect(!read.out.contains("com.apple.quarantine"))
    }

    @Test func readsTheQuarantineFlagFromAListing() {
        #expect(UpdateVerifier.hasQuarantine(listing: "/x/ColimaBar.app: com.apple.quarantine\n"))
        #expect(!UpdateVerifier.hasQuarantine(listing: ""))
        #expect(!UpdateVerifier.hasQuarantine(listing: "/x/file: com.apple.provenance\n"))
    }

    @Test func clearsTheQuarantineFlagOfAWholeTree() async throws {
        let tmp = try TempFolder()
        let app = try await FakeBundle.make(in: tmp.path, sign: false)
        let inner = app.appendingPathComponent("Contents/Resources/colima-ctl.sh").path
        let set = await Shell.run(["/usr/bin/xattr", "-w", "com.apple.quarantine", "0081;00000000;Test;", inner])
        #expect(set.ok)
        try await UpdateVerifier.clearQuarantine(app)
        let read = await Shell.run(["/usr/bin/xattr", "-r", app.path], includeStderr: true)
        #expect(!read.out.contains("com.apple.quarantine"))
    }

    @Test func aMissingBundleFailsTheQuarantineCheck() async {
        await #expect(throws: UpdateError.self) {
            try await UpdateVerifier.clearQuarantine(URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString).app"))
        }
    }

    @Test func refusesAnUnpackedAppOver100MB() async throws {
        let tmp = try TempFolder()
        let app = try await FakeBundle.make(in: tmp.path, sign: false)
        // A sparse file of 101 MB: it counts by size and takes little disk.
        let big = app.appendingPathComponent("Contents/Resources/big.bin")
        FileManager.default.createFile(atPath: big.path, contents: nil)
        let h = try FileHandle(forWritingTo: big)
        try h.truncate(atOffset: UInt64(UpdatePolicy.maxUnpackedBytes + 1_048_576))
        try h.close()
        try await FakeBundle.zip(["ColimaBar.app"], in: tmp.path, to: "\(tmp.path)/big.zip")
        let into = "\(tmp.path)/out"
        try FileManager.default.createDirectory(atPath: into, withIntermediateDirectories: true)
        await #expect(throws: UpdateError.self) {
            try await UpdateVerifier.unpack(
                zip: URL(fileURLWithPath: "\(tmp.path)/big.zip"), into: URL(fileURLWithPath: into))
        }
    }

    @Test func refusesAZipWhoseAppIsASymlink() async throws {
        let tmp = try TempFolder()
        let real = "\(tmp.path)/real"
        try FileManager.default.createDirectory(atPath: real, withIntermediateDirectories: true)
        let packed = "\(tmp.path)/packed"
        try FileManager.default.createDirectory(atPath: packed, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: "\(packed)/ColimaBar.app", withDestinationPath: real)
        try await FakeBundle.zip(["ColimaBar.app"], in: packed, to: "\(tmp.path)/link.zip")
        let into = "\(tmp.path)/out"
        try FileManager.default.createDirectory(atPath: into, withIntermediateDirectories: true)
        await #expect(throws: UpdateError.self) {
            try await UpdateVerifier.unpack(
                zip: URL(fileURLWithPath: "\(tmp.path)/link.zip"), into: URL(fileURLWithPath: into))
        }
    }

    @Test func theCodesignArgumentsCarryTheIdentifierRequirement() {
        let args = UpdateVerifier.codesignArguments("/x/ColimaBar.app")
        #expect(
            args == [
                "/usr/bin/codesign", "--verify", "--deep", "--strict", "-R", "=identifier \"com.imohitkr.ColimaBar\"",
                "/x/ColimaBar.app",
            ])
    }
}
