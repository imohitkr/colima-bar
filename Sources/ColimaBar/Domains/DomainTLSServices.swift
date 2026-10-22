import Foundation
import Security

/// What the model needs from the disk, the keychain and the TLS stack to run
/// HTTPS. The model tests give it a fake, so no test creates a CA on disk,
/// touches the login keychain or the trust settings, or makes a keychain.
protocol DomainTLSServicing: AnyObject, Sendable {
    /// The saved CA, or nil.
    func loadCA() -> LocalCA?
    /// The saved CA if it permits exactly the names of `permitted`, else a new one that it saves.
    func prepareCA(permitted: [String]) throws -> LocalCA
    /// Deletes the key and the files of the CA.
    func removeCAFiles()
    /// Adds the CA to the login keychain and trusts it. It blocks while the dialog shows.
    func install(_ ca: LocalCA) -> TrustStore.Outcome
    /// Removes the trust and the certificate of the CA. It blocks while the dialog shows.
    func uninstall(_ ca: LocalCA) -> TrustStore.Outcome
    /// Removes the trust and the certificates labelled like the CA, when its files are gone. It blocks while a dialog shows.
    func uninstallLeftovers() -> TrustStore.Outcome
    func isTrusted(_ ca: LocalCA) -> Bool
    /// True when the trust settings of the user hold an entry for the CA. It reads only.
    func hasTrustSettings(_ ca: LocalCA) -> Bool
    /// Deletes the certificate of the CA from the keychain. It changes no trust setting and shows no dialog.
    func deleteCertificate(_ ca: LocalCA)
    func makeProvider(ca: LocalCA) -> TLSIdentityProvider?
    /// Deletes the temporary keychains of processes that are gone.
    func cleanStale()
    /// Connects with one name under each of `suffixes`.
    func selfTest(port: UInt16, ca: LocalCA, suffixes: [String]) async -> Bool
    /// The path of the `ca.pem` file.
    var certificatePath: String { get }
}

/// The real services: the folder in Application Support, the login keychain
/// and the identity providers.
final class SystemDomainTLS: DomainTLSServicing, @unchecked Sendable {
    /// The folder of the CA files. A test gives its own folder.
    private let directory: String

    init(directory: String = LocalCAStore.dir) { self.directory = directory }

    var certificatePath: String { LocalCAStore.pemPath(dir: directory) }

    func loadCA() -> LocalCA? { LocalCAStore.load(dir: directory) }

    func prepareCA(permitted: [String]) throws -> LocalCA {
        if let ca = loadCA(), Set(ca.permitted) == Set(permitted) { return ca }
        let ca = try LocalCA.create(permitted: permitted)
        try LocalCAStore.save(ca, dir: directory)
        return ca
    }

    func removeCAFiles() { LocalCAStore.remove(dir: directory, removingEmptyParent: true) }
    func uninstallLeftovers() -> TrustStore.Outcome { TrustStore.removeLabelled() }
    func install(_ ca: LocalCA) -> TrustStore.Outcome { TrustStore.install(ca) }
    func uninstall(_ ca: LocalCA) -> TrustStore.Outcome { TrustStore.remove(ca) }
    func isTrusted(_ ca: LocalCA) -> Bool { TrustStore.isTrusted(ca) }
    func hasTrustSettings(_ ca: LocalCA) -> Bool { TrustStore.hasSettings(ca) }
    func deleteCertificate(_ ca: LocalCA) { TrustStore.deleteCertificate(ca) }
    func makeProvider(ca: LocalCA) -> TLSIdentityProvider? { TLSIdentityProviders.make(ca: ca) }
    func cleanStale() { TLSIdentityProviders.cleanStale() }
    func selfTest(port: UInt16, ca: LocalCA, suffixes: [String]) async -> Bool {
        await DomainTLSServer.selfTest(port: port, ca: ca, suffixes: suffixes)
    }
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
    func uninstallLeftovers() -> TrustStore.Outcome { .failed(errSecNotAvailable) }
    func isTrusted(_ ca: LocalCA) -> Bool { false }
    func hasTrustSettings(_ ca: LocalCA) -> Bool { false }
    func deleteCertificate(_ ca: LocalCA) {}
    func makeProvider(ca: LocalCA) -> TLSIdentityProvider? { nil }
    func cleanStale() {}
    func selfTest(port: UInt16, ca: LocalCA, suffixes: [String]) async -> Bool { false }
}
