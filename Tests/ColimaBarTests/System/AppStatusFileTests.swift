import Darwin
import Foundation
import Testing

@testable import ColimaBar

@Suite struct AppStatusFileTests {
    private let status = AppStatus(
        pid: 4242, version: "0.10.0", autoStopAt: ["default": Date(timeIntervalSince1970: 1_800_000_000)])
    private let started = Date(timeIntervalSinceNow: -3600)

    private func path(_ tmp: TempFolder) -> String { "\(tmp.path)/cache/app-status.json" }

    private func mode(_ path: String) throws -> Int {
        (try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int) ?? -1
    }

    @Test func theFileHasMode0600InAFolderWithMode0700() throws {
        let tmp = try TempFolder()
        try AppStatusFile.write(status, path: path(tmp))
        #expect(try mode(path(tmp)) == 0o600)
        #expect(try mode("\(tmp.path)/cache") == 0o700)
    }

    @Test func aWrittenStatusIsReadBack() throws {
        let tmp = try TempFolder()
        try AppStatusFile.write(status, path: path(tmp))
        #expect(AppStatusFile.read(path: path(tmp), startTime: { _ in started }) == status)
    }

    @Test func aNewWriteReplacesTheFileAndLeavesNoTemporaryFile() throws {
        let tmp = try TempFolder()
        try AppStatusFile.write(status, path: path(tmp))
        var newer = status
        newer.autoStopAt = [:]
        try AppStatusFile.write(newer, path: path(tmp))
        #expect(AppStatusFile.read(path: path(tmp), startTime: { _ in started }) == newer)
        #expect(try FileManager.default.contentsOfDirectory(atPath: "\(tmp.path)/cache") == ["app-status.json"])
    }

    @Test func aLinkAtTheTemporaryPathIsNotFollowed() throws {
        let tmp = try TempFolder()
        try FileManager.default.createDirectory(atPath: "\(tmp.path)/cache", withIntermediateDirectories: true)
        let victim = "\(tmp.path)/victim.txt"
        try "keep".write(toFile: victim, atomically: true, encoding: .utf8)
        symlink(victim, "\(path(tmp)).\(getpid()).tmp")
        try AppStatusFile.write(status, path: path(tmp))
        #expect(try String(contentsOfFile: victim, encoding: .utf8) == "keep")
        #expect(AppStatusFile.read(path: path(tmp), startTime: { _ in started }) == status)
    }

    @Test func aMissingFolderMakesTheWriteFail() throws {
        let tmp = try TempFolder()
        // A file where the folder should be.
        FileManager.default.createFile(atPath: "\(tmp.path)/cache", contents: nil)
        #expect(throws: (any Error).self) { try AppStatusFile.write(status, path: path(tmp)) }
    }

    @Test func noFileMeansNoApp() throws {
        let tmp = try TempFolder()
        #expect(AppStatusFile.read(path: path(tmp), startTime: { _ in started }) == nil)
    }

    @Test func aStatusOfAGoneAppMeansNoApp() throws {
        let tmp = try TempFolder()
        try AppStatusFile.write(status, path: path(tmp))
        #expect(AppStatusFile.read(path: path(tmp), startTime: { _ in nil }) == nil)
    }

    @Test func aFileThatIsNotAStatusMeansNoApp() throws {
        let tmp = try TempFolder()
        try FileManager.default.createDirectory(atPath: "\(tmp.path)/cache", withIntermediateDirectories: true)
        try "not json".write(toFile: path(tmp), atomically: true, encoding: .utf8)
        #expect(AppStatusFile.read(path: path(tmp), startTime: { _ in started }) == nil)
    }

    @Test func aTooBigFileMeansNoApp() throws {
        let tmp = try TempFolder()
        try FileManager.default.createDirectory(atPath: "\(tmp.path)/cache", withIntermediateDirectories: true)
        let big = Data(repeating: 0x20, count: AppStatusFile.maxBytes + 1)
        try big.write(to: URL(fileURLWithPath: path(tmp)))
        #expect(AppStatusFile.read(path: path(tmp), startTime: { _ in started }) == nil)
    }

    @Test func aLinkAtThePathMeansNoApp() throws {
        let tmp = try TempFolder()
        try AppStatusFile.write(status, path: "\(tmp.path)/real.json")
        symlink("\(tmp.path)/real.json", "\(tmp.path)/link.json")
        #expect(AppStatusFile.read(path: "\(tmp.path)/link.json", startTime: { _ in started }) == nil)
    }

    @Test func theFileGoesAwayOnlyForItsOwnPID() throws {
        let tmp = try TempFolder()
        try AppStatusFile.write(status, path: path(tmp))
        AppStatusFile.removeIfOwned(by: 1, path: path(tmp))
        #expect(FileManager.default.fileExists(atPath: path(tmp)))
        AppStatusFile.removeIfOwned(by: 4242, path: path(tmp))
        #expect(!FileManager.default.fileExists(atPath: path(tmp)))
    }

    @Test func removingAMissingOrForeignFileChangesNothing() throws {
        let tmp = try TempFolder()
        AppStatusFile.removeIfOwned(by: 4242, path: path(tmp))  // no file: no error
        try FileManager.default.createDirectory(atPath: "\(tmp.path)/cache", withIntermediateDirectories: true)
        try "not json".write(toFile: path(tmp), atomically: true, encoding: .utf8)
        AppStatusFile.removeIfOwned(by: 4242, path: path(tmp))
        #expect(FileManager.default.fileExists(atPath: path(tmp)))
    }
}
