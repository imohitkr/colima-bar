import Foundation
import Security

/// The only code that touches the login keychain and the trust settings. It
/// adds the certificate of the CA (never a key) to the login keychain and
/// trusts it for this user, for the SSL policy only. `install` and `remove`
/// make macOS ask for the password of the user: they block until the user
/// answers. No test calls them (`DomainTLSServicing` has a fake).
enum TrustStore {
    enum Outcome: Equatable, Sendable {
        case done
        case cancelled
        case failed(OSStatus)
    }

    /// The trust settings: trusted as a root, for the SSL policy only.
    static func trustSettings() -> CFArray {
        let settings: [String: Any] = [
            kSecTrustSettingsPolicy as String: SecPolicyCreateSSL(true, nil),
            kSecTrustSettingsResult as String: NSNumber(value: SecTrustSettingsResult.trustRoot.rawValue),
        ]
        return [settings] as CFArray
    }

    private static func isCancel(_ status: OSStatus) -> Bool {
        status == errAuthorizationCanceled || status == errSecUserCanceled
    }

    /// Adds the certificate to the login keychain and trusts it. One dialog.
    /// A cancel removes the certificate again.
    static func install(_ ca: LocalCA) -> Outcome {
        // A test process never changes the keychain or the trust settings.
        guard !TestProcess.isRunning else { return .failed(errSecNotAvailable) }
        // No `kSecUseDataProtectionKeychain`: a Mac app without a signed
        // entitlement gets -34018 from the data protection keychain.
        let add: [CFString: Any] = [
            kSecClass: kSecClassCertificate, kSecValueRef: ca.certificate, kSecAttrLabel: ca.commonName,
        ]
        let added = SecItemAdd(add as CFDictionary, nil)
        guard added == errSecSuccess || added == errSecDuplicateItem else { return .failed(added) }
        let status = SecTrustSettingsSetTrustSettings(ca.certificate, .user, trustSettings())
        if status == errSecSuccess { return .done }
        deleteCertificate(ca)
        return isCancel(status) ? .cancelled : .failed(status)
    }

    /// Removes the trust setting (one dialog) and the certificate. The
    /// certificate goes even if the user cancels the dialog.
    static func remove(_ ca: LocalCA) -> Outcome {
        guard !TestProcess.isRunning else { return .failed(errSecNotAvailable) }
        let status = SecTrustSettingsRemoveTrustSettings(ca.certificate, .user)
        deleteCertificate(ca)
        if status == errSecSuccess || status == errSecItemNotFound { return .done }
        return isCancel(status) ? .cancelled : .failed(status)
    }

    private static func deleteCertificate(_ ca: LocalCA) {
        SecItemDelete([kSecClass: kSecClassCertificate, kSecValueRef: ca.certificate] as CFDictionary)
    }

    /// True when the user trust settings list the CA and the system accepts
    /// a test leaf of it. It reads only: no dialog.
    static func isTrusted(_ ca: LocalCA) -> Bool {
        var settings: CFArray?
        guard SecTrustSettingsCopyTrustSettings(ca.certificate, .user, &settings) == errSecSuccess,
            settings != nil,
            let leaf = try? ca.mintLeaf(names: ["\(DomainName.selfTestLabel).\(DomainName.localhost)"])
        else { return false }
        var trust: SecTrust?
        let policy = SecPolicyCreateSSL(true, "\(DomainName.selfTestLabel).\(DomainName.localhost)" as CFString)
        guard SecTrustCreateWithCertificates([leaf.certificate] as CFArray, policy, &trust) == errSecSuccess,
            let trust
        else { return false }
        return SecTrustEvaluateWithError(trust, nil)
    }
}
