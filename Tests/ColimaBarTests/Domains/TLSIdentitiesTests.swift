import Darwin
import Foundation
import LocalAuthentication
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

    @Test func importingNeedsNoKeychain() throws {
        // The identity is made in memory: no keychain gets the key or the
        // certificate. The queries only read, and they never show a dialog.
        // An authentication context that may not show anything: a query that
        // would need a prompt fails at once.
        let noUI = LAContext()
        noUI.interactionNotAllowed = true
        let ca = try LocalCA.create(permitted: ["localhost"])
        for host in ["a", "b", "c"] {
            let leaf = try ca.mintLeaf(names: ["\(host).localhost"])
            _ = try PKCS12.identity(certificate: leaf.certificate, key: leaf.key)
            let keyID = X509Builder.keyID(try LocalCA.publicX963(of: leaf.key))
            let keyQuery: [CFString: Any] = [
                kSecClass: kSecClassKey, kSecAttrApplicationLabel: Data(keyID),
                kSecUseAuthenticationContext: noUI, kSecReturnRef: true,
            ]
            #expect(SecItemCopyMatching(keyQuery as CFDictionary, nil) == errSecItemNotFound)
            // A certificate is found by the hash of its public key, which is the same SHA-1, and by its name.
            for match: [CFString: Any] in [
                [kSecAttrPublicKeyHash: Data(keyID)],
                [kSecAttrLabel: SecCertificateCopySubjectSummary(leaf.certificate) as String? ?? "a.localhost"],
            ] {
                var query: [CFString: Any] = [
                    kSecClass: kSecClassCertificate, kSecUseAuthenticationContext: noUI, kSecReturnRef: true,
                ]
                query.merge(match) { $1 }
                #expect(SecItemCopyMatching(query as CFDictionary, nil) == errSecItemNotFound)
            }
        }
    }

    // MARK: The format

    /// Known answers of the key derivation of RFC 7292 appendix B with
    /// SHA-256. Made with OpenSSL 4.0.3: `openssl kdf -keylen N -kdfopt
    /// digest:SHA256 -kdfopt hexpass:0073006d006500670000 -kdfopt
    /// hexsalt:SALT -kdfopt iter:I -kdfopt id:ID PKCS12KDF` (the password
    /// "smeg" as a BMPString with its terminating zero). The 80 and 100
    /// byte outputs need more than one round of the derivation.
    @Test func theKeyDerivationMatchesOpenSSL() {
        let salt: [UInt8] = [0x0a, 0x58, 0xcf, 0x64, 0x53, 0x0d, 0x82, 0x3b]
        let cases: [(id: UInt8, iterations: Int, expected: String)] = [
            (1, 1, "051e124a87e3b8a04f600b0e35f97bda1f80b129d2363a27"),
            (3, 1, "42e08f32ccab5b650351e21990f112bda599598df0836272730d9f10ef93cf76"),
            (
                1, 2000,
                "8a0b66539fb2ee31202063c1c9c555752278ccaf0cf2dc2b3cf03f168b1d9f8b6cce492ce009c9845fa6e629563122f2ee9424ff6e5e6e159fa2ee97d304f07929ad56af34dd18335618a333e7caca96"
            ),
            (
                3, 7,
                "1dec449393337004256b083350a61a36795a9a045dd1b0440b4a4a14c1e6e1c51d38b5d63a41d753b57297dd3b4f2051bef7c1f164afc629f2bc93040e0a88b2c812111d4c403c7f2fefa9f58319ddfdd43d9ced39cac290998cad4a70378a8a76bf2271"
            ),
        ]
        for c in cases {
            let out = PKCS12.kdf(
                password: "smeg", salt: salt, iterations: c.iterations, id: c.id, length: c.expected.count / 2)
            #expect(out.map { String(format: "%02x", $0) }.joined() == c.expected, "id \(c.id), \(c.iterations) rounds")
        }
        // A salt longer than one block of 64 bytes (the same salt as OpenSSL: 01 02 ... 46).
        let long = PKCS12.kdf(password: "smeg", salt: Array(1...70), iterations: 3, id: 1, length: 80)
        #expect(
            long.map { String(format: "%02x", $0) }.joined()
                == "2a034a4e67f9ddc028d5d26358dcd0b00009eff4ac16e72b5055f81d0155a68e9054148cbec40c7b6f11c5269b8aeb64bf0289c915f3352df5a7093d006d2bc9f29da945ef4f880598a064877e6ecf19"
        )
    }

    @Test func aTamperedFileIsRefused() throws {
        let ca = try LocalCA.create(permitted: ["localhost"])
        let leaf = try ca.mintLeaf(names: ["a.localhost"])
        let file = try PKCS12.file(certificate: leaf.certificate, key: leaf.key, password: "p")
        _ = try PKCS12.importIdentity(Data(file), password: "p")  // the untouched file imports
        // A flipped bit in the middle (the safe contents) and at the end (the MAC).
        for index in [file.count / 2, file.count - 5] {
            var bad = file
            bad[index] ^= 0x01
            #expect(throws: (any Error).self, "byte \(index)") {
                _ = try PKCS12.importIdentity(Data(bad), password: "p")
            }
        }
    }

    @Test func aTruncatedFileIsRefused() throws {
        let ca = try LocalCA.create(permitted: ["localhost"])
        let leaf = try ca.mintLeaf(names: ["a.localhost"])
        let file = try PKCS12.file(certificate: leaf.certificate, key: leaf.key, password: "p")
        for cut in [1, 10, file.count / 2] {
            #expect(throws: (any Error).self, "cut \(cut)") {
                _ = try PKCS12.importIdentity(Data(file.dropLast(cut)), password: "p")
            }
        }
        #expect(throws: (any Error).self) { _ = try PKCS12.importIdentity(Data(), password: "p") }
    }

    @Test func twoFilesOfTheSameCertificateAndKeyDiffer() throws {
        let ca = try LocalCA.create(permitted: ["localhost"])
        let leaf = try ca.mintLeaf(names: ["a.localhost"])
        let first = try PKCS12.file(certificate: leaf.certificate, key: leaf.key, password: "p")
        let second = try PKCS12.file(certificate: leaf.certificate, key: leaf.key, password: "p")
        #expect(first != second)  // new salts and a new IV each time
        #expect(first.count == second.count)
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

    @Test func theOldCacheFolderGoesWhenItIsEmptyAfterTheClean() throws {
        let fm = FileManager.default
        let temp = try TempFolder()
        let folder = temp.path + "/tls"
        try fm.createDirectory(atPath: folder, withIntermediateDirectories: false)
        fm.createFile(atPath: folder + "/tls-99999999.keychain-db", contents: Data("x".utf8))
        TLSIdentities.cleanStale(cacheDir: folder)
        #expect(!fm.fileExists(atPath: folder))
        #expect(fm.fileExists(atPath: temp.path))
    }

    @Test func theOldCacheFolderStaysWhenSomethingElseIsInIt() throws {
        let fm = FileManager.default
        let temp = try TempFolder()
        let folder = temp.path + "/tls"
        try fm.createDirectory(atPath: folder, withIntermediateDirectories: false)
        fm.createFile(atPath: folder + "/tls-99999999.keychain-db", contents: Data("x".utf8))
        fm.createFile(atPath: folder + "/notes.txt", contents: Data("x".utf8))
        TLSIdentities.cleanStale(cacheDir: folder)
        #expect(try fm.contentsOfDirectory(atPath: folder) == ["notes.txt"])
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
