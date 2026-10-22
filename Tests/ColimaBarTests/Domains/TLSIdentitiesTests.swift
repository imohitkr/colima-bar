import Darwin
import Foundation
import Security
import Testing

@testable import ColimaBar

/// The identities live in memory. These tests use no keychain: the folders of
/// the clean-up are temporary, and none uses the cache folder of the user.
@Suite struct TLSIdentitiesTests {
    @Test func aLeafMakesAnIdentityWithItsPrivateKey() throws {
        let ca = try LocalCA.create(permitted: ["localhost"])
        let leaf = try ca.mintLeaf(names: ["a.localhost"])
        let identity = try PKCS12.identity(certificate: leaf.certificate, key: leaf.key)
        var key: SecKey?
        #expect(SecIdentityCopyPrivateKey(identity, &key) == errSecSuccess && key != nil)
        var certificate: SecCertificate?
        #expect(SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess)
        #expect(SecCertificateCopyData(try #require(certificate)) == SecCertificateCopyData(leaf.certificate))
        // The key of the identity signs what the certificate verifies.
        let data = Data("x".utf8) as CFData
        let signature = SecKeyCreateSignature(try #require(key), .ecdsaSignatureMessageX962SHA256, data, nil)
        let publicKey = try #require(SecCertificateCopyKey(leaf.certificate))
        #expect(
            SecKeyVerifySignature(
                publicKey, .ecdsaSignatureMessageX962SHA256, data, try #require(signature), nil))
    }

    @Test func theSelfTestPasses() throws {
        let ca = try LocalCA.create(permitted: ["localhost"])
        #expect(TLSIdentities.selfTest(ca: ca))
    }

    @Test func importingNeedsNoKeychain() async throws {
        // The identity is made in memory: the user keychains stay as they are.
        let before = await keychainList()
        let ca = try LocalCA.create(permitted: ["localhost"])
        for host in ["a", "b", "c"] {
            let leaf = try ca.mintLeaf(names: ["\(host).localhost"])
            _ = try PKCS12.identity(certificate: leaf.certificate, key: leaf.key)
        }
        #expect(await keychainList() == before)
    }

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

    @Test func eachIdentityHasItsOwnKey() throws {
        let ca = try LocalCA.create(permitted: ["localhost"])
        let one = try ca.mintLeaf(names: ["a.localhost"])
        let two = try ca.mintLeaf(names: ["b.localhost"])
        let first = try PKCS12.file(certificate: one.certificate, key: one.key, password: "p")
        let second = try PKCS12.file(certificate: two.certificate, key: two.key, password: "p")
        #expect(first != second)
        // A wrong password does not import.
        #expect(throws: (any Error).self) {
            _ = try PKCS12.importIdentity(Data(first), password: "other")
        }
    }

    @Test func aKeyThatIsNotP256IsRefused() throws {
        let ca = try LocalCA.create(permitted: ["localhost"])
        let leaf = try ca.mintLeaf(names: ["a.localhost"])
        let attributes: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits: 2048]
        let rsa = try #require(SecKeyCreateRandomKey(attributes as CFDictionary, nil))
        #expect(throws: (any Error).self) { try PKCS12.identity(certificate: leaf.certificate, key: rsa) }
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
        TLSIdentities.cleanStale(cacheDir: temp.path)
        let left = Set(try fm.contentsOfDirectory(atPath: temp.path))
        #expect(left == [mine, "notes.txt", "tls-abc.keychain-db"])
        #expect(fm.fileExists(atPath: "/etc/hosts"))
    }

    @Test func aLiveProcessKeepsItsKeychainFile() throws {
        let temp = try TempFolder()
        // The parent of the test process is alive.
        let name = "tls-\(getppid()).keychain-db"
        FileManager.default.createFile(atPath: temp.path + "/" + name, contents: Data("x".utf8))
        TLSIdentities.cleanStale(cacheDir: temp.path)
        #expect(FileManager.default.fileExists(atPath: temp.path + "/" + name))
    }

    @Test func aTestProcessLeavesTheCacheFolderOfTheUserAlone() {
        // cleanStale returns at once for the real folder in a test process.
        TLSIdentities.cleanStale()
        #expect(Paths.tlsCacheDir.hasSuffix("/Library/Caches/com.imohitkr.ColimaBar/tls"))
    }

    @Test func theNameOfAKeychainFileHoldsThePID() {
        #expect(TLSIdentities.pid(ofFile: "tls-123.keychain-db") == 123)
        #expect(TLSIdentities.pid(ofFile: "tls-123.keychain") == 123)
        #expect(TLSIdentities.pid(ofFile: "tls-123") == nil)
        #expect(TLSIdentities.pid(ofFile: "tls-x.keychain-db") == nil)
        #expect(TLSIdentities.pid(ofFile: "other-1.keychain-db") == nil)
    }
}
