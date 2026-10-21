import Foundation
import Testing

@testable import ColimaBar

/// The real services work in a folder of the test. No test touches the folder
/// of the user, the login keychain or a trust setting.
@Suite struct DomainTLSServicesTests {
    private func services(_ temp: TempFolder) -> SystemDomainTLS {
        SystemDomainTLS(directory: temp.path + "/domains")
    }

    @Test func aSavedCAWithTheSameNamesIsReused() throws {
        let temp = try TempFolder()
        let tls = services(temp)
        let first = try tls.prepareCA(permitted: ["localhost"])
        let again = try tls.prepareCA(permitted: ["localhost"])
        #expect(again.der == first.der)
        #expect(tls.loadCA()?.der == first.der)
    }

    @Test func aCAThatPermitsOtherNamesIsReplaced() throws {
        let temp = try TempFolder()
        let tls = services(temp)
        let first = try tls.prepareCA(permitted: ["localhost"])
        let wider = try tls.prepareCA(permitted: ["localhost", "colima.internal"])
        #expect(wider.der != first.der)
        #expect(Set(wider.permitted) == ["localhost", "colima.internal"])
        #expect(tls.loadCA()?.der == wider.der)
        let narrower = try tls.prepareCA(permitted: ["localhost"])
        #expect(narrower.der != wider.der && tls.loadCA()?.der == narrower.der)
    }

    @Test func theOrderOfTheNamesDoesNotMatter() throws {
        let temp = try TempFolder()
        let tls = services(temp)
        let first = try tls.prepareCA(permitted: ["localhost", "colima.internal"])
        let reordered = try tls.prepareCA(permitted: ["colima.internal", "localhost"])
        #expect(reordered.der == first.der)
    }

    @Test func removingTheFilesDeletesTheFolder() throws {
        let temp = try TempFolder()
        let tls = services(temp)
        _ = try tls.prepareCA(permitted: ["localhost"])
        #expect(tls.certificatePath == temp.path + "/domains/ca.pem")
        #expect(FileManager.default.fileExists(atPath: tls.certificatePath))
        tls.removeCAFiles()
        #expect(tls.loadCA() == nil && !FileManager.default.fileExists(atPath: temp.path + "/domains"))
    }

    @Test func theServicesOfATestProcessChangeNoKeychainAndNoTrust() throws {
        let tls = SystemDomainTLS(directory: Paths.domainsDir)
        let ca = try LocalCA.create(permitted: ["localhost"])
        #expect(throws: POSIXError.self) { try tls.prepareCA(permitted: ["localhost"]) }
        #expect(tls.install(ca) == .failed(errSecNotAvailable))
        #expect(tls.uninstall(ca) == .failed(errSecNotAvailable))
        #expect(tls.uninstallLeftovers() == .failed(errSecNotAvailable))
        let inert = InertDomainTLS()
        #expect(inert.loadCA() == nil && inert.uninstallLeftovers() == .failed(errSecNotAvailable))
    }
}
