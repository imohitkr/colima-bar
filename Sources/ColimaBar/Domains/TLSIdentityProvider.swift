import Foundation
import Security

/// Makes a `SecIdentity` of a leaf certificate and its key. Network.framework
/// wants an identity for a TLS server, and an identity needs the key in a
/// keychain. The ephemeral file keychain does that without the login
/// keychain. The private `SecIdentityCreate` needs no keychain at all.
protocol TLSIdentityProvider: AnyObject, Sendable {
    /// For the log and the diagnostics: "file keychain" or "private API".
    var name: String { get }
    func identity(certificate: SecCertificate, key: SecKey) throws -> SecIdentity
    /// Deletes the key and the certificate of a leaf that the cache dropped.
    func discard(certificate: SecCertificate, key: SecKey)
    /// Called after a wake.
    func unlockIfNeeded()
    /// Called at quit and when HTTPS turns off.
    func removeAll()
}

enum TLSIdentityProviders {
    /// The folder of the temporary keychains.
    static var cacheDir: String { Paths.tlsCacheDir }

    /// The first provider whose self-test passes, in the order of `candidates`.
    static func make(
        ca: LocalCA, cacheDir: String = cacheDir,
        candidates: [@Sendable (String) -> TLSIdentityProvider?] = [
            { FileKeychainIdentityProvider(cacheDir: $0) }, { _ in PrivateIdentityProvider() },
        ]
    ) -> TLSIdentityProvider? {
        for candidate in candidates {
            guard let provider = candidate(cacheDir) else { continue }
            if selfTest(provider, ca: ca) { return provider }
            provider.removeAll()
        }
        return nil
    }

    /// Mints a leaf for the self-test name, makes an identity of it, and
    /// checks that the identity has its private key and that the key signs
    /// data which the public key of the certificate verifies.
    static func selfTest(_ provider: TLSIdentityProvider, ca: LocalCA) -> Bool {
        guard let leaf = try? ca.mintLeaf(names: ["\(DomainName.selfTestLabel).\(DomainName.localhost)"]) else {
            return false
        }
        // The test leaf must not stay in the keychain, also if the test fails.
        defer { provider.discard(certificate: leaf.certificate, key: leaf.key) }
        guard let identity = try? provider.identity(certificate: leaf.certificate, key: leaf.key) else { return false }
        var privateKey: SecKey?
        guard SecIdentityCopyPrivateKey(identity, &privateKey) == errSecSuccess, let privateKey,
            let publicKey = SecCertificateCopyKey(leaf.certificate)
        else { return false }
        let data = Data("colimabar-selftest".utf8) as CFData
        guard
            let signature = SecKeyCreateSignature(privateKey, .ecdsaSignatureMessageX962SHA256, data, nil)
        else { return false }
        return SecKeyVerifySignature(publicKey, .ecdsaSignatureMessageX962SHA256, data, signature, nil)
    }

    /// Deletes the `tls-PID.keychain-db` files of processes that are gone,
    /// and the entries of that name that are not regular files.
    static func cleanStale(cacheDir: String = cacheDir) {
        if TestProcess.isRunning, cacheDir == Paths.tlsCacheDir { return }
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: cacheDir) else { return }
        for name in names {
            guard let pid = FileKeychainIdentityProvider.pid(ofFile: name) else { continue }
            let path = "\(cacheDir)/\(name)"
            var info = stat()
            let regular = lstat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFREG
            if regular, pid == Int(getpid()) || ProcessProbe.isAlive(pid: pid) { continue }
            try? fm.removeItem(atPath: path)
        }
    }
}
