import Darwin
import Foundation
import Security

/// The first choice of `TLSIdentityProvider`: a file keychain in the cache
/// folder. It has an absolute path (a relative one lands in
/// `~/Library/Keychains`), a random password that lives in memory only, and
/// no place in the search list. `removeAll` deletes it, and
/// `TLSIdentityProviders.cleanStale` deletes the file of a process that died.
/// An `NSLock` guards `keychain`.
///
/// SecKeychain is deprecated, and no public API makes an identity of a key
/// that is not in a keychain. See TLSIdentityProvider.
final class FileKeychainIdentityProvider: TLSIdentityProvider, @unchecked Sendable {
    let name = "file keychain"
    let path: String
    private let password: [UInt8]
    private let lock = NSLock()
    private var keychain: SecKeychain?

    /// nil if the folder or the keychain cannot be made.
    init?(cacheDir: String) {
        guard cacheDir.hasPrefix("/") else { return nil }
        // A test process makes its keychains in a folder of its own.
        if TestProcess.isRunning, cacheDir == Paths.tlsCacheDir { return nil }
        path = "\(cacheDir)/tls-\(getpid()).keychain-db"
        var random = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, random.count, &random) == errSecSuccess else { return nil }
        password = Array(Data(random).base64EncodedString().utf8)
        let fm = FileManager.default
        do {
            try fm.createDirectory(
                atPath: cacheDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } catch { return nil }
        try? fm.removeItem(atPath: path)
        var created: SecKeychain?
        // SecKeychain is deprecated; see TLSIdentityProvider.
        guard SecKeychainCreate(path, UInt32(password.count), password, false, nil, &created) == errSecSuccess,
            let created
        else { return nil }
        // A locked keychain would fail each handshake: never lock it.
        var settings = SecKeychainSettings(
            version: UInt32(SEC_KEYCHAIN_SETTINGS_VERS1), lockOnSleep: false, useLockInterval: false,
            lockInterval: UInt32(Int32.max))
        _ = SecKeychainSetSettings(created, &settings)
        keychain = created
    }

    deinit { removeAll() }

    /// The PID in the name `tls-PID.keychain...`, or nil for another name.
    static func pid(ofFile name: String) -> Int? {
        guard name.hasPrefix("tls-") else { return nil }
        let digits = name.dropFirst(4).prefix { $0.isNumber }
        guard !digits.isEmpty, name.dropFirst(4 + digits.count).hasPrefix(".keychain") else { return nil }
        return Int(digits)
    }

    func identity(certificate: SecCertificate, key: SecKey) throws -> SecIdentity {
        let kc = try lock.withLock { () throws -> SecKeychain in
            guard let keychain else { throw POSIXError(.ENOENT) }
            return keychain
        }
        // The label of the key is the key ID: it is what makes
        // SecIdentityCreateWithCertificate find the key of the certificate.
        let x963 = try LocalCA.publicX963(of: key)
        let keyItem: [CFString: Any] = [
            kSecClass: kSecClassKey, kSecValueRef: key, kSecUseKeychain: kc,
            kSecAttrApplicationLabel: Data(X509Builder.keyID(x963)), kSecAttrLabel: "colimabar-leaf",
        ]
        var status = SecItemAdd(keyItem as CFDictionary, nil)
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
        let certItem: [CFString: Any] = [
            kSecClass: kSecClassCertificate, kSecValueRef: certificate, kSecUseKeychain: kc,
        ]
        status = SecItemAdd(certItem as CFDictionary, nil)
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
        var identity: SecIdentity?
        status = SecIdentityCreateWithCertificate(kc, certificate, &identity)
        guard status == errSecSuccess, let identity else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
        return identity
    }

    func discard(certificate: SecCertificate, key: SecKey) {
        guard let kc = lock.withLock({ keychain }), let x963 = try? LocalCA.publicX963(of: key) else { return }
        let list = [kc] as CFArray
        SecItemDelete(
            [kSecClass: kSecClassCertificate, kSecValueRef: certificate, kSecMatchSearchList: list] as CFDictionary)
        SecItemDelete(
            [
                kSecClass: kSecClassKey, kSecAttrApplicationLabel: Data(X509Builder.keyID(x963)),
                kSecMatchSearchList: list,
            ] as CFDictionary)
    }

    /// The number of keys and certificates in the keychain. A test reads it.
    var itemCount: Int {
        guard let kc = lock.withLock({ keychain }) else { return 0 }
        return [kSecClassKey, kSecClassCertificate].reduce(0) { total, cls in
            let query: [CFString: Any] = [
                kSecClass: cls, kSecMatchSearchList: [kc] as CFArray, kSecMatchLimit: kSecMatchLimitAll,
                kSecReturnRef: true,
            ]
            var result: CFTypeRef?
            guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
                let items = result as? [AnyObject]
            else { return total }
            return total + items.count
        }
    }

    func unlockIfNeeded() {
        lock.withLock {
            guard let keychain else { return }
            var status = SecKeychainStatus()
            if SecKeychainGetStatus(keychain, &status) == errSecSuccess,
                status & SecKeychainStatus(kSecUnlockStateStatus) != 0
            {
                return
            }
            _ = SecKeychainUnlock(keychain, UInt32(password.count), password, true)
        }
    }

    func removeAll() {
        lock.withLock {
            if let keychain { _ = SecKeychainDelete(keychain) }
            keychain = nil
            unlink(path)
        }
    }
}
