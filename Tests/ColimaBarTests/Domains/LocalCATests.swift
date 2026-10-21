import Foundation
import Security
import Testing

@testable import ColimaBar

@Suite struct LocalCATests {
    private let day: TimeInterval = 86400

    @Test func aNewCAHasATenYearLifeAndTheNameConstraints() throws {
        let now = Date()
        let ca = try LocalCA.create(permitted: ["localhost"], now: now)
        #expect(ca.permitted == ["localhost"])
        #expect(ca.publicX963.count == 65 && ca.publicX963.first == 0x04)
        #expect(ca.sha1.count == 20)
        #expect(ca.keyID == X509Builder.keyID(ca.publicX963))
        #expect(LocalCA.validityDays == 3650)
        // The key is not a keychain item.
        let attributes = SecKeyCopyAttributes(ca.key) as? [CFString: Any]
        #expect((attributes?[kSecAttrIsPermanent] as? Bool) != true)
    }

    @Test func eachCAHasItsOwnKeyAndName() throws {
        let a = try LocalCA.create(permitted: ["localhost"])
        let b = try LocalCA.create(permitted: ["localhost"])
        #expect(a.keyID != b.keyID && a.commonName != b.commonName && a.der != b.der)
    }

    @Test func aLeafLivesThirtyDaysAndHasTheNameOfItsCA() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let ca = try LocalCA.create(permitted: ["localhost"], now: now)
        let leaf = try ca.mintLeaf(names: ["web.shop.localhost"], now: now)
        #expect(leaf.notAfter == now.addingTimeInterval(30 * day))
        #expect(SecCertificateCopySubjectSummary(leaf.certificate) as String? == "web.shop.localhost")
        let serial = try #require(SecCertificateCopySerialNumberData(leaf.certificate, nil) as Data?)
        #expect(serial.first.map { $0 & 0x80 == 0 } == true)
        let key = try #require(SecCertificateCopyKey(leaf.certificate))
        #expect(try LocalCA.publicX963(of: key) == (try LocalCA.publicX963(of: leaf.key)))
    }

    @Test func aLongNameStaysInTheSANAndNotInTheCommonName() throws {
        let ca = try LocalCA.create(permitted: ["localhost"])
        let name = String(repeating: "a", count: 60) + "." + String(repeating: "b", count: 60) + ".localhost"
        let leaf = try ca.mintLeaf(names: [name])
        #expect(SecCertificateCopySubjectSummary(leaf.certificate) as String? == "ColimaBar")
    }

    @Test func restoreGivesBackTheSameCA() throws {
        let ca = try LocalCA.create(permitted: ["localhost", "colima.internal"])
        let back = try LocalCA.restore(certificateDER: ca.der, keyX963: try ca.keyX963())
        #expect(back.der == ca.der && back.keyID == ca.keyID && back.name == ca.name)
        #expect(back.permitted == ["localhost", "colima.internal"])
        // The restored key signs leaves that the CA certificate accepts.
        let leaf = try back.mintLeaf(names: ["a.localhost"])
        #expect(SecCertificateCopySubjectSummary(leaf.certificate) as String? == "a.localhost")
    }

    @Test func restoreRefusesAKeyThatDoesNotMatchTheCertificate() throws {
        let a = try LocalCA.create(permitted: ["localhost"])
        let b = try LocalCA.create(permitted: ["localhost"])
        #expect(throws: LocalCA.Failure.keyMismatch) {
            try LocalCA.restore(certificateDER: a.der, keyX963: try b.keyX963())
        }
    }

    @Test func restoreRefusesBadInput() throws {
        let ca = try LocalCA.create(permitted: ["localhost"])
        let key = try ca.keyX963()
        #expect(throws: LocalCA.Failure.key) {
            try LocalCA.restore(certificateDER: ca.der, keyX963: Array(key.dropLast()))
        }
        #expect(throws: LocalCA.Failure.certificate) { try LocalCA.restore(certificateDER: [1, 2, 3], keyX963: key) }
        #expect(throws: LocalCA.Failure.certificate) {
            try LocalCA.restore(certificateDER: Array(ca.der.dropLast(10)), keyX963: key)
        }
    }
}
