import Darwin
import Foundation
import Security
import os

/// The identities of the TLS server. Network.framework wants a
/// `SecIdentity` for each leaf. `PKCS12` makes one in memory from the
/// certificate and its key, so no keychain is involved.
enum TLSIdentities {
    /// The folder where older versions kept temporary keychains.
    static var cacheDir: String { Paths.tlsCacheDir }

    private static let log = Logger(category: "domains")

    /// What a log may show of an error: our own cases (status codes only)
    /// as they are, any other error as its domain and code. A system error
    /// can carry names and paths in its text, so that stays out.
    static func logText(_ error: any Error) -> String {
        switch error {
        case let e as PKCS12.Failure: return "PKCS12 \(e)"
        case let e as LocalCA.Failure: return "LocalCA \(e)"
        default:
            let e = error as NSError
            return "\(e.domain) \(e.code)"
        }
    }

    /// Mints a leaf for the self-test name, makes an identity of it, and
    /// checks that the identity has its private key and that the key signs
    /// data which the public key of the certificate verifies. A failure
    /// goes to the log with the step.
    static func selfTest(ca: LocalCA) -> Bool {
        func fail(_ step: String, _ detail: String = "") -> Bool {
            log.error("the identity self-test failed at \(step, privacy: .public) \(detail, privacy: .public)")
            return false
        }
        let leaf: (certificate: SecCertificate, key: SecKey, notAfter: Date)
        do {
            leaf = try ca.mintLeaf(names: ["\(DomainName.selfTestLabel).\(DomainName.localhost)"])
        } catch { return fail("minting the leaf", logText(error)) }
        let identity: SecIdentity
        do {
            identity = try PKCS12.identity(certificate: leaf.certificate, key: leaf.key)
        } catch { return fail("making the identity", logText(error)) }
        var privateKey: SecKey?
        let keyStatus = SecIdentityCopyPrivateKey(identity, &privateKey)
        guard keyStatus == errSecSuccess, let privateKey else { return fail("reading the private key", "\(keyStatus)") }
        guard let publicKey = SecCertificateCopyKey(leaf.certificate) else { return fail("reading the public key") }
        let data = Data("colimabar-selftest".utf8) as CFData
        var signError: Unmanaged<CFError>?
        guard
            let signature = SecKeyCreateSignature(privateKey, .ecdsaSignatureMessageX962SHA256, data, &signError)
        else { return fail("signing", signError.map { logText($0.takeRetainedValue()) } ?? "") }
        guard SecKeyVerifySignature(publicKey, .ecdsaSignatureMessageX962SHA256, data, signature, nil) else {
            return fail("verifying the signature")
        }
        return true
    }

    /// Deletes the `tls-PID.keychain-db` files that older versions left
    /// behind, and the entries of that name that are not regular files. The
    /// files of a process that still runs stay. An empty folder is removed.
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
        // The folder goes too when nothing is left in it. `rmdir` fails on a
        // folder that has entries, so nothing else is ever deleted here.
        if ((try? fm.contentsOfDirectory(atPath: cacheDir)) ?? ["x"]).isEmpty { rmdir(cacheDir) }
    }

    /// The PID in the name `tls-PID.keychain...`, or nil for another name.
    static func pid(ofFile name: String) -> Int? {
        guard name.hasPrefix("tls-") else { return nil }
        let digits = name.dropFirst(4).prefix { $0.isNumber }
        guard !digits.isEmpty, name.dropFirst(4 + digits.count).hasPrefix(".keychain") else { return nil }
        return Int(digits)
    }
}
