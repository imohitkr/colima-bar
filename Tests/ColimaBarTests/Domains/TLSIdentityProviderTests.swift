import Darwin
import Foundation
import Security
import Testing

@testable import ColimaBar

/// The file keychains of these tests live in a temporary folder and are
/// deleted at the end of each test. No test uses the cache folder of the user.
@Suite struct TLSIdentityProviderTests {
    private func keychainList() async -> String {
        await onOwnThread {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
            p.arguments = ["list-keychains", "-d", "user"]
            let out = Pipe()
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            guard (try? p.run()) != nil else { return "" }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return String(decoding: data, as: UTF8.self)
        }
    }

    @Test func theFileKeychainMakesAnIdentityWithItsPrivateKey() async throws {
        let temp = try TempFolder()
        let before = await keychainList()
        let ca = try LocalCA.create(permitted: ["localhost"])
        let provider = try #require(FileKeychainIdentityProvider(cacheDir: temp.path))
        #expect(provider.name == "file keychain")
        #expect(provider.path == "\(temp.path)/tls-\(getpid()).keychain-db")
        #expect(FileManager.default.fileExists(atPath: provider.path))
        #expect(TLSIdentityProviders.selfTest(provider, ca: ca))
        let leaf = try ca.mintLeaf(names: ["a.localhost"])
        let identity = try provider.identity(certificate: leaf.certificate, key: leaf.key)
        var key: SecKey?
        #expect(SecIdentityCopyPrivateKey(identity, &key) == errSecSuccess && key != nil)
        provider.unlockIfNeeded()
        #expect(TLSIdentityProviders.selfTest(provider, ca: ca))
        // The keychain is not in the search list.
        #expect(await keychainList() == before)
        provider.removeAll()
        #expect(!FileManager.default.fileExists(atPath: provider.path))
        #expect(await keychainList() == before)
        #expect(throws: (any Error).self) { try provider.identity(certificate: leaf.certificate, key: leaf.key) }
    }

    @Test func theFolderOfTheKeychainIsPrivate() throws {
        let temp = try TempFolder()
        let dir = temp.path + "/tls"
        let provider = try #require(FileKeychainIdentityProvider(cacheDir: dir))
        defer { provider.removeAll() }
        var info = stat()
        #expect(lstat(dir, &info) == 0 && info.st_mode & 0o777 == 0o700)
    }

    @Test func aRelativePathIsRefused() {
        #expect(FileKeychainIdentityProvider(cacheDir: "relative/tls") == nil)
    }

    @Test func aTestProcessNeverUsesTheCacheFolderOfTheUser() {
        #expect(FileKeychainIdentityProvider(cacheDir: Paths.tlsCacheDir) == nil)
        #expect(Paths.tlsCacheDir.hasSuffix("/Library/Caches/com.imohitkr.ColimaBar/tls"))
    }

    @Test func thePrivateProviderMakesAnIdentityInMemory() throws {
        let ca = try LocalCA.create(permitted: ["localhost"])
        let provider = PrivateIdentityProvider()
        #expect(provider.name == "private API")
        #expect(TLSIdentityProviders.selfTest(provider, ca: ca))
        provider.unlockIfNeeded()
        provider.removeAll()
    }

    @Test func theFactoryTakesTheFirstProviderThatPasses() throws {
        let temp = try TempFolder()
        let ca = try LocalCA.create(permitted: ["localhost"])
        let first = TLSIdentityProviders.make(ca: ca, cacheDir: temp.path)
        #expect(first?.name == "file keychain")
        first?.removeAll()
        // The first candidate cannot be made: the second one serves.
        let second = TLSIdentityProviders.make(
            ca: ca, cacheDir: temp.path, candidates: [{ _ in nil }, { _ in PrivateIdentityProvider() }])
        #expect(second?.name == "private API")
        #expect(TLSIdentityProviders.make(ca: ca, cacheDir: temp.path, candidates: [{ _ in nil }]) == nil)
    }

    private final class BrokenProvider: TLSIdentityProvider, @unchecked Sendable {
        let name = "broken"
        func identity(certificate: SecCertificate, key: SecKey) throws -> SecIdentity { throw POSIXError(.EIO) }
        func discard(certificate: SecCertificate, key: SecKey) {}
        func unlockIfNeeded() {}
        func removeAll() {}
    }

    @Test func aProviderThatFailsTheSelfTestIsSkipped() throws {
        let ca = try LocalCA.create(permitted: ["localhost"])
        #expect(!TLSIdentityProviders.selfTest(BrokenProvider(), ca: ca))
        let made = TLSIdentityProviders.make(
            ca: ca, cacheDir: "", candidates: [{ _ in BrokenProvider() }, { _ in PrivateIdentityProvider() }])
        #expect(made?.name == "private API")
    }

    @Test func staleKeychainFilesOfDeadProcessesAreDeleted() throws {
        let temp = try TempFolder()
        let fm = FileManager.default
        let mine = "tls-\(getpid()).keychain-db"
        for name in [
            mine, "tls-99999999.keychain-db", "tls-99999999.keychain-db-journal", "notes.txt", "tls-abc.keychain-db",
        ] {
            fm.createFile(atPath: temp.path + "/" + name, contents: Data("x".utf8))
        }
        // Something that is not a regular file also goes, even for a live process.
        try fm.createDirectory(atPath: temp.path + "/tls-\(getppid()).keychain-db", withIntermediateDirectories: false)
        symlink("/etc/hosts", temp.path + "/tls-99999998.keychain-db")
        TLSIdentityProviders.cleanStale(cacheDir: temp.path)
        let left = Set(try fm.contentsOfDirectory(atPath: temp.path))
        #expect(left == [mine, "notes.txt", "tls-abc.keychain-db"])
        #expect(fm.fileExists(atPath: "/etc/hosts"))
    }

    @Test func aLiveProcessKeepsItsKeychainFile() throws {
        let temp = try TempFolder()
        // The parent of the test process is alive.
        let name = "tls-\(getppid()).keychain-db"
        FileManager.default.createFile(atPath: temp.path + "/" + name, contents: Data("x".utf8))
        TLSIdentityProviders.cleanStale(cacheDir: temp.path)
        #expect(FileManager.default.fileExists(atPath: temp.path + "/" + name))
    }

    @Test func theNameOfAKeychainFileHoldsThePID() {
        #expect(FileKeychainIdentityProvider.pid(ofFile: "tls-123.keychain-db") == 123)
        #expect(FileKeychainIdentityProvider.pid(ofFile: "tls-123.keychain") == 123)
        #expect(FileKeychainIdentityProvider.pid(ofFile: "tls-123") == nil)
        #expect(FileKeychainIdentityProvider.pid(ofFile: "tls-x.keychain-db") == nil)
        #expect(FileKeychainIdentityProvider.pid(ofFile: "other-1.keychain-db") == nil)
    }

    @Test func theSelfTestLeavesNothingInTheKeychain() throws {
        let temp = try TempFolder()
        let ca = try LocalCA.create(permitted: ["localhost"])
        let provider = try #require(FileKeychainIdentityProvider(cacheDir: temp.path))
        defer { provider.removeAll() }
        #expect(TLSIdentityProviders.selfTest(provider, ca: ca))
        #expect(provider.itemCount == 0)
    }

    @Test func aFailedCertificateAddLeavesNoKeyInTheKeychain() throws {
        let temp = try TempFolder()
        let ca = try LocalCA.create(permitted: ["localhost"])
        let provider = try #require(FileKeychainIdentityProvider(cacheDir: temp.path))
        defer { provider.removeAll() }
        let leaf = try ca.mintLeaf(names: ["a.localhost"])
        // The certificate is in the keychain already, so adding it again fails after the key went in.
        var keychain: SecKeychain?
        #expect(SecKeychainOpen(provider.path, &keychain) == errSecSuccess)
        let added = SecItemAdd(
            [kSecClass: kSecClassCertificate, kSecValueRef: leaf.certificate, kSecUseKeychain: try #require(keychain)]
                as CFDictionary, nil)
        #expect(added == errSecSuccess)
        #expect(provider.itemCount == 1)
        #expect(throws: (any Error).self) { try provider.identity(certificate: leaf.certificate, key: leaf.key) }
        #expect(provider.itemCount == 0)
    }
}
