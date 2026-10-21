import Foundation
import Security

/// The fallback of `TLSIdentityProvider`: the private `SecIdentityCreate` of
/// Security.framework joins a certificate and a key in memory. It touches no
/// keychain. It is an undocumented symbol, so it is the second choice.
final class PrivateIdentityProvider: TLSIdentityProvider, @unchecked Sendable {
    @_silgen_name("SecIdentityCreate")
    private static func secIdentityCreate(_ a: CFAllocator?, _ cert: SecCertificate, _ key: SecKey) -> Unmanaged<
        SecIdentity
    >?

    let name = "private API"

    func identity(certificate: SecCertificate, key: SecKey) throws -> SecIdentity {
        guard let identity = Self.secIdentityCreate(nil, certificate, key)?.takeRetainedValue() else {
            throw POSIXError(.EIO)
        }
        return identity
    }

    func unlockIfNeeded() {}
    func removeAll() {}
}
