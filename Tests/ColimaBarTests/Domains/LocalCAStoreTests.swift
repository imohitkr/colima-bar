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

    @Test func aTestProcessNeverWritesTheFolderOfTheUser() throws {
        let ca = try LocalCA.create(permitted: ["localhost"])
        #expect(throws: POSIXError.self) { try LocalCAStore.save(ca) }
        LocalCAStore.remove()  // does nothing here
        #expect(LocalCAStore.dir == Paths.domainsDir)
        #expect(Paths.domainsDir.hasSuffix("/Library/Application Support/ColimaBar/domains"))
    }
}
