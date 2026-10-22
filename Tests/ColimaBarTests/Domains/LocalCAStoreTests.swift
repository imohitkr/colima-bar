import Darwin
import Foundation
import Testing

@testable import ColimaBar

/// Every test uses a folder in a temporary directory, never the folder of the user.
@Suite struct LocalCAStoreTests {
    private func mode(_ path: String) -> mode_t {
        var info = stat()
        return lstat(path, &info) == 0 ? info.st_mode & 0o777 : 0
    }

    private func saved(_ temp: TempFolder) throws -> (ca: LocalCA, dir: String) {
        let dir = temp.path + "/domains"
        let ca = try LocalCA.create(permitted: ["localhost"])
        try LocalCAStore.save(ca, dir: dir)
        return (ca, dir)
    }

    @Test func aSavedCAComesBack() throws {
        let temp = try TempFolder()
        let (ca, dir) = try saved(temp)
        let back = try #require(LocalCAStore.load(dir: dir))
        #expect(back.der == ca.der && back.keyID == ca.keyID && back.permitted == ["localhost"])
        #expect(try back.keyX963() == ca.keyX963())
    }

    @Test func theFilesAndTheFolderArePrivate() throws {
        let temp = try TempFolder()
        let (ca, dir) = try saved(temp)
        #expect(mode(dir) == 0o700)
        #expect(mode(dir + "/ca-key.raw") == 0o600)
        #expect(mode(dir + "/ca.der") == 0o600)
        #expect(mode(dir + "/ca.pem") == 0o644)
        #expect(try String(contentsOfFile: dir + "/ca.pem", encoding: .utf8) == X509Builder.pem(ca.der))
        #expect(FileManager.default.contents(atPath: dir + "/ca-key.raw")?.count == 97)
        let values = try URL(fileURLWithPath: dir).resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(values.isExcludedFromBackup == true)
        #expect(LocalCAStore.pemPath(dir: dir) == dir + "/ca.pem")
    }

    @Test func aSecondSaveReplacesTheFiles() throws {
        let temp = try TempFolder()
        let (_, dir) = try saved(temp)
        let next = try LocalCA.create(permitted: ["localhost"])
        try LocalCAStore.save(next, dir: dir)
        #expect(LocalCAStore.load(dir: dir)?.keyID == next.keyID)
        #expect(mode(dir + "/ca-key.raw") == 0o600)
    }

    @Test func aSaveLeavesNoStagingFolderAndReplacesAHalfWrittenOne() throws {
        let temp = try TempFolder()
        let dir = temp.path + "/domains"
        // A crash of an earlier save left a staging folder.
        try FileManager.default.createDirectory(atPath: dir + ".new", withIntermediateDirectories: true)
        try "half".write(toFile: dir + ".new/ca-key.raw", atomically: true, encoding: .utf8)
        let ca = try LocalCA.create(permitted: ["localhost"])
        try LocalCAStore.save(ca, dir: dir)
        #expect(!FileManager.default.fileExists(atPath: dir + ".new"))
        #expect(LocalCAStore.load(dir: dir)?.der == ca.der)
        let next = try LocalCA.create(permitted: ["localhost"])
        try LocalCAStore.save(next, dir: dir)
        #expect(!FileManager.default.fileExists(atPath: dir + ".new"))
        #expect(LocalCAStore.load(dir: dir)?.der == next.der)
        // The files of the old set are gone, not mixed in.
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: dir).sorted() == ["ca-key.raw", "ca.der", "ca.pem"])
    }

    @Test func aHalfWrittenStagingFolderNeverLoads() throws {
        let temp = try TempFolder()
        let (ca, dir) = try saved(temp)
        let other = try LocalCA.create(permitted: ["localhost"])
        // A certificate with the key of another CA, as a crash between two writes would leave it.
        let mixed = temp.path + "/mixed"
        try FileManager.default.createDirectory(
            atPath: mixed, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        for (name, data) in [("ca.der", Data(other.der)), ("ca-key.raw", Data(try ca.keyX963()))] {
            let writer = try PrivateFileWriter(destination: mixed + "/" + name, replace: true)
            try writer.write(data)
            try writer.commit()
        }
        #expect(LocalCAStore.load(dir: mixed) == nil)
        #expect(LocalCAStore.load(dir: dir)?.der == ca.der)
    }

    @Test func aSaveReplacesASymlinkAtTheFolderWithoutFollowingIt() throws {
        let temp = try TempFolder()
        let target = temp.path + "/target"
        try FileManager.default.createDirectory(atPath: target, withIntermediateDirectories: false)
        try "keep".write(toFile: target + "/keep.txt", atomically: true, encoding: .utf8)
        let dir = temp.path + "/domains"
        symlink(target, dir)
        let ca = try LocalCA.create(permitted: ["localhost"])
        try LocalCAStore.save(ca, dir: dir)
        #expect(LocalCAStore.load(dir: dir)?.der == ca.der)
        #expect(FileManager.default.fileExists(atPath: target + "/keep.txt"))
        #expect(!FileManager.default.fileExists(atPath: target + "/ca-key.raw"))
    }

    @Test func nothingLoadsFromAMissingFolder() throws {
        let temp = try TempFolder()
        #expect(LocalCAStore.load(dir: temp.path + "/none") == nil)
    }

    @Test func aKeyThatIsASymlinkIsRefused() throws {
        let temp = try TempFolder()
        let (_, dir) = try saved(temp)
        let real = temp.path + "/real-key"
        try FileManager.default.moveItem(atPath: dir + "/ca-key.raw", toPath: real)
        symlink(real, dir + "/ca-key.raw")
        #expect(LocalCAStore.load(dir: dir) == nil)
    }

    @Test func aFolderThatIsASymlinkIsRefused() throws {
        let temp = try TempFolder()
        let (_, dir) = try saved(temp)
        let link = temp.path + "/link"
        symlink(dir, link)
        #expect(LocalCAStore.load(dir: link) == nil)
    }

    @Test func aKeyOrCertificateThatOthersCanReadIsRefused() throws {
        let temp = try TempFolder()
        let (_, dir) = try saved(temp)
        chmod(dir + "/ca-key.raw", 0o644)
        #expect(LocalCAStore.load(dir: dir) == nil)
        chmod(dir + "/ca-key.raw", 0o600)
        #expect(LocalCAStore.load(dir: dir) != nil)
        chmod(dir + "/ca.der", 0o644)
        #expect(LocalCAStore.load(dir: dir) == nil)
        chmod(dir + "/ca.der", 0o600)
        chmod(dir, 0o755)
        #expect(LocalCAStore.load(dir: dir) == nil)
    }

    @Test func aTruncatedOrForeignKeyIsRefused() throws {
        let temp = try TempFolder()
        let (ca, dir) = try saved(temp)
        let key = try Data(contentsOf: URL(fileURLWithPath: dir + "/ca-key.raw"))
        let writer = try PrivateFileWriter(destination: dir + "/ca-key.raw", replace: true)
        try writer.write(key.prefix(50))
        try writer.commit()
        #expect(LocalCAStore.load(dir: dir) == nil)
        let other = try LocalCA.create(permitted: ["localhost"])
        let again = try PrivateFileWriter(destination: dir + "/ca-key.raw", replace: true)
        try again.write(Data(try other.keyX963()))
        try again.commit()
        #expect(LocalCAStore.load(dir: dir) == nil)
        #expect(ca.keyID != other.keyID)
    }

    @Test func removeDeletesTheKeyAndTheFolder() throws {
        let temp = try TempFolder()
        let (_, dir) = try saved(temp)
        LocalCAStore.remove(dir: dir)
        #expect(!FileManager.default.fileExists(atPath: dir))
        #expect(LocalCAStore.load(dir: dir) == nil)
        LocalCAStore.remove(dir: dir)  // nothing left: no error
    }

    @Test func removeAlsoDeletesAStagingFolder() throws {
        let temp = try TempFolder()
        let (_, dir) = try saved(temp)
        try FileManager.default.createDirectory(atPath: dir + ".new", withIntermediateDirectories: true)
        LocalCAStore.remove(dir: dir)
        #expect(!FileManager.default.fileExists(atPath: dir + ".new"))
    }

    @Test func aTestProcessNeverWritesTheFolderOfTheUser() throws {
        let ca = try LocalCA.create(permitted: ["localhost"])
        #expect(throws: POSIXError.self) { try LocalCAStore.save(ca) }
        LocalCAStore.remove()  // does nothing here
        #expect(LocalCAStore.dir == Paths.domainsDir)
        #expect(Paths.domainsDir.hasSuffix("/Library/Application Support/ColimaBar/domains"))
    }

    @Test func aFileInPlaceOfTheFolderIsReplacedWithoutLosingTheNewFiles() throws {
        let temp = try TempFolder()
        let dir = temp.path + "/domains"
        try "not a folder".write(toFile: dir, atomically: true, encoding: .utf8)
        let ca = try LocalCA.create(permitted: ["localhost"])
        try LocalCAStore.save(ca, dir: dir)
        #expect(LocalCAStore.load(dir: dir)?.keyID == ca.keyID)
        #expect(!FileManager.default.fileExists(atPath: dir + ".old"))
        #expect(!FileManager.default.fileExists(atPath: dir + ".new"))
    }

    @Test func aLinkInPlaceOfTheFolderIsReplacedAndNeverFollowed() throws {
        let temp = try TempFolder()
        let dir = temp.path + "/domains"
        let target = temp.path + "/target"
        try FileManager.default.createDirectory(atPath: target, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: dir, withDestinationPath: target)
        let ca = try LocalCA.create(permitted: ["localhost"])
        try LocalCAStore.save(ca, dir: dir)
        #expect(LocalCAStore.load(dir: dir)?.keyID == ca.keyID)
        #expect(try FileManager.default.contentsOfDirectory(atPath: target).isEmpty)
    }

    @Test func aLoadAfterACrashBetweenTheTwoRenamesBringsTheOldFilesBack() throws {
        let temp = try TempFolder()
        let (ca, dir) = try saved(temp)
        // The crash left the old folder as `.old` and no folder at the path.
        try FileManager.default.moveItem(atPath: dir, toPath: dir + ".old")
        #expect(LocalCAStore.load(dir: dir)?.keyID == ca.keyID)
        #expect(!FileManager.default.fileExists(atPath: dir + ".old"))
    }

    @Test func anOldFolderNextToAFolderIsDeletedAtLoadAndAtSave() throws {
        let temp = try TempFolder()
        let (ca, dir) = try saved(temp)
        try FileManager.default.createDirectory(atPath: dir + ".old", withIntermediateDirectories: true)
        #expect(LocalCAStore.load(dir: dir)?.keyID == ca.keyID)
        #expect(!FileManager.default.fileExists(atPath: dir + ".old"))
        try FileManager.default.createDirectory(atPath: dir + ".old", withIntermediateDirectories: true)
        let next = try LocalCA.create(permitted: ["localhost"])
        try LocalCAStore.save(next, dir: dir)
        #expect(!FileManager.default.fileExists(atPath: dir + ".old"))
        #expect(LocalCAStore.load(dir: dir)?.keyID == next.keyID)
    }

    @Test func removeDeletesTheOldFolderToo() throws {
        let temp = try TempFolder()
        let (_, dir) = try saved(temp)
        try FileManager.default.createDirectory(atPath: dir + ".old", withIntermediateDirectories: true)
        LocalCAStore.remove(dir: dir)
        #expect(!FileManager.default.fileExists(atPath: dir))
        #expect(!FileManager.default.fileExists(atPath: dir + ".old"))
    }
}
