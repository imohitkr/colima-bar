import Foundation
import Testing

@testable import ColimaBar

@Suite struct DockerConfigFileTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private let utc = TimeZone(identifier: "UTC")!
    private func set(_ d: Data) -> Data? { DockerConfig.settingCredsStore("osxkeychain", in: d) }
    private func mode(_ path: String) throws -> Int {
        try #require(FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int)
    }

    @Test func theBackupNameHasTheDateAndTime() {
        #expect(
            DockerConfigFile.backupPath(for: "/h/.docker/config.json", now: now, timeZone: utc)
                == "/h/.docker/config.json.colimabar-20231114-221320")
    }

    @Test func editSavesAPrivateBackupAndKeepsTheModeOfTheFile() throws {
        let dir = try TempFolder()
        let file = dir.path + "/config.json"
        try #"{"credsStore": "desktop"}"#.write(toFile: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: file)
        let outcome = DockerConfigFile.edit(path: file, now: now, timeZone: utc, set)
        let backup = dir.path + "/config.json.colimabar-20231114-221320"
        #expect(outcome == .changed(backup: backup))
        #expect(try String(contentsOfFile: backup, encoding: .utf8) == #"{"credsStore": "desktop"}"#)
        #expect(try mode(backup) == 0o600)
        #expect(try mode(file) == 0o640)
        #expect(try String(contentsOfFile: file, encoding: .utf8).contains("osxkeychain"))
    }

    @Test func editWritesThroughASymlinkAndKeepsTheLink() throws {
        let dir = try TempFolder()
        let real = dir.path + "/dotfiles-config.json"
        let link = dir.path + "/config.json"
        try "{}".write(toFile: real, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: "dotfiles-config.json")
        _ = DockerConfigFile.edit(path: link, now: now, timeZone: utc, set)
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: link)) == "dotfiles-config.json")
        #expect(try String(contentsOfFile: real, encoding: .utf8).contains("osxkeychain"))
        // The backup sits next to the real file.
        #expect(FileManager.default.fileExists(atPath: real + ".colimabar-20231114-221320"))
    }

    @Test func aFileThatIsNotJSONStaysAsItIs() throws {
        let dir = try TempFolder()
        let file = dir.path + "/config.json"
        try "{oops".write(toFile: file, atomically: true, encoding: .utf8)
        #expect(DockerConfigFile.edit(path: file, now: now, timeZone: utc, set) == .invalid)
        #expect(try String(contentsOfFile: file, encoding: .utf8) == "{oops")
        let left = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(left == ["config.json"])
    }

    @Test func aMissingFileIsCreatedWithNoBackup() throws {
        let dir = try TempFolder()
        let file = dir.path + "/sub/config.json"
        #expect(DockerConfigFile.edit(path: file, now: now, timeZone: utc, set) == .changed(backup: nil))
        #expect(try String(contentsOfFile: file, encoding: .utf8).contains("osxkeychain"))
    }

    @Test func aFileThatExistsButCannotBeReadIsNeverReplaced() throws {
        let dir = try TempFolder()
        let file = dir.path + "/config.json"
        try #"{"auths": {"a.io": {"auth": "x"}}, "credsStore": "desktop"}"#.write(
            toFile: file, atomically: true, encoding: .utf8)
        chmod(file, 0)
        defer { chmod(file, 0o600) }
        #expect(DockerConfigFile.read(path: file) == .unreadable)
        guard case .failed(let why) = DockerConfigFile.edit(path: file, now: now, timeZone: utc, set) else {
            Issue.record("edit must fail for an unreadable file")
            return
        }
        #expect(why.contains("Cannot read"))
        chmod(file, 0o600)
        #expect(try String(contentsOfFile: file, encoding: .utf8).contains("auths"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["config.json"])
    }

    @Test func readTellsAMissingFileFromADataFile() throws {
        let dir = try TempFolder()
        #expect(DockerConfigFile.read(path: dir.path + "/none.json") == .missing)
        try "{}".write(toFile: dir.path + "/a.json", atomically: true, encoding: .utf8)
        #expect(DockerConfigFile.read(path: dir.path + "/a.json") == .data(Data("{}".utf8)))
    }
}
