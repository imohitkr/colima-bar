import Darwin
import Foundation
import Security

/// The identities of the TLS server. Network.framework wants a
/// `SecIdentity` for each leaf. `PKCS12` makes one in memory from the
/// certificate and its key, so no keychain is involved.
enum TLSIdentities {
    /// The folder where older versions kept temporary keychains.
    static var cacheDir: String { Paths.tlsCacheDir }

    /// Mints a leaf for the self-test name, makes an identity of it, and
    /// checks that the identity has its private key and that the key signs
    /// data which the public key of the certificate verifies.
    static func selfTest(ca: LocalCA) -> Bool {
        guard let leaf = try? ca.mintLeaf(names: ["\(DomainName.selfTestLabel).\(DomainName.localhost)"]),
            let identity = try? PKCS12.identity(certificate: leaf.certificate, key: leaf.key)
        else { return false }
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

    /// Deletes the `tls-PID.keychain-db` files that older versions left
    /// behind, and the entries of that name that are not regular files. The
    /// files of a process that still runs stay.
    static func cleanStale(cacheDir: String = cacheDir) {
        if TestProcess.isRunning, cacheDir == Paths.tlsCacheDir { return }
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: cacheDir) else { return }
        for name in names {
            guard let pid = pid(ofFile: name) else { continue }
            let path = "\(cacheDir)/\(name)"
            var info = stat()
            let regular = lstat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFREG
            if regular, pid == Int(getpid()) || ProcessProbe.isAlive(pid: pid) { continue }
            if regular { unlink(path) } else { try? fm.removeItem(atPath: path) }
        }
    }

    /// The PID in the name `tls-PID.keychain...`, or nil for another name.
    static func pid(ofFile name: String) -> Int? {
        guard name.hasPrefix("tls-") else { return nil }
        let digits = name.dropFirst(4).prefix { $0.isNumber }
        guard !digits.isEmpty, name.dropFirst(4 + digits.count).hasPrefix(".keychain") else { return nil }
        return Int(digits)
    }
}
