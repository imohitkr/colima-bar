import Foundation
import Security

/// What the model needs from the disk, the keychain and the TLS stack to run
/// HTTPS. The model tests give it a fake, so no test creates a CA on disk,
/// touches the login keychain or the trust settings, or makes a keychain.
protocol DomainTLSServicing: AnyObject, Sendable {
    /// The saved CA, or nil.
    func loadCA() -> LocalCA?
    /// The saved CA, or a new one that it saves.
    func prepareCA(permitted: [String]) throws -> LocalCA
    /// Deletes the key and the files of the CA.
    func removeCAFiles()
    /// Adds the CA to the login keychain and trusts it. It blocks while the dialog shows.
    func install(_ ca: LocalCA) -> TrustStore.Outcome
    /// Removes the trust and the certificate of the CA. It blocks while the dialog shows.
    func uninstall(_ ca: LocalCA) -> TrustStore.Outcome
    func isTrusted(_ ca: LocalCA) -> Bool
    func makeProvider(ca: LocalCA) -> TLSIdentityProvider?
    /// Deletes the temporary keychains of processes that are gone.
    func cleanStale()
    func selfTest(port: UInt16, ca: LocalCA) async -> Bool
    /// The path of the `ca.pem` file.
    var certificatePath: String { get }
}

/// The real services: the folder in Application Support, the login keychain
/// and the identity providers.
final class SystemDomainTLS: DomainTLSServicing, @unchecked Sendable {
    var certificatePath: String { LocalCAStore.pemPath() }

    func loadCA() -> LocalCA? { LocalCAStore.load() }

    func prepareCA(permitted: [String]) throws -> LocalCA {
        if let ca = LocalCAStore.load(), ca.permitted == permitted { return ca }
        let ca = try LocalCA.create(permitted: permitted)
        try LocalCAStore.save(ca)
        return ca
    }

    func removeCAFiles() { LocalCAStore.remove() }
    func install(_ ca: LocalCA) -> TrustStore.Outcome { TrustStore.install(ca) }
    func uninstall(_ ca: LocalCA) -> TrustStore.Outcome { TrustStore.remove(ca) }
    func isTrusted(_ ca: LocalCA) -> Bool { TrustStore.isTrusted(ca) }
    func makeProvider(ca: LocalCA) -> TLSIdentityProvider? { TLSIdentityProviders.make(ca: ca) }
    func cleanStale() { TLSIdentityProviders.cleanStale() }
    func selfTest(port: UInt16, ca: LocalCA) async -> Bool { await DomainTLSServer.selfTest(port: port, ca: ca) }
}

/// Services that do nothing and fail. A model in a test process uses them
/// when the test gives no other services, so a forgotten argument cannot
/// create a CA or touch a keychain.
final class InertDomainTLS: DomainTLSServicing, @unchecked Sendable {
    var certificatePath: String { "" }
    func loadCA() -> LocalCA? { nil }
    func prepareCA(permitted: [String]) throws -> LocalCA { throw POSIXError(.EPERM) }
    func removeCAFiles() {}
    func install(_ ca: LocalCA) -> TrustStore.Outcome { .failed(errSecNotAvailable) }
    func uninstall(_ ca: LocalCA) -> TrustStore.Outcome { .failed(errSecNotAvailable) }
    func isTrusted(_ ca: LocalCA) -> Bool { false }
    func makeProvider(ca: LocalCA) -> TLSIdentityProvider? { nil }
    func cleanStale() {}
    func selfTest(port: UInt16, ca: LocalCA) async -> Bool { false }
}
