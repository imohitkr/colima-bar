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
        // The certificate has the real dates: an hour early, ten years long.
        let info = try #require(X509Builder.readCA(certificateDER: ca.der))
        #expect(abs(info.notBefore.timeIntervalSince(now.addingTimeInterval(-LocalCA.backdate))) < 1)
        #expect(abs(info.notAfter.timeIntervalSince(now.addingTimeInterval(3650 * day))) < 1)
        #expect(info.isCA && info.issuer == info.subject)
        // The key is not a keychain item: the attribute is there and false.
        let attributes = try #require(SecKeyCopyAttributes(ca.key) as? [CFString: Any])
        let permanent = try #require(attributes[kSecAttrIsPermanent])
        #expect((permanent as? Bool) == false || (permanent as? Int) == 0)
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

    // MARK: - Restore checks the certificate and the key

    /// A certificate that is signed by `signer` for the key `subject`.
    private func certificate(
        subject: SecKey, signer: SecKey, issuerName: [UInt8]? = nil, kind: X509Builder.Spec.Kind? = nil,
        from: Date = Date().addingTimeInterval(-3600), to: Date = Date().addingTimeInterval(86400 * 365)
    ) throws -> [UInt8] {
        let x963 = try LocalCA.publicX963(of: subject)
        let name = X509Builder.name(cn: "ColimaBar Local CA test", organization: "ColimaBar")
        let spec = X509Builder.Spec(
            serial: X509Builder.randomSerial(), subjectCN: "ColimaBar Local CA test", organization: "ColimaBar",
            issuerName: issuerName ?? name, notBefore: from, notAfter: to, publicKeyX963: x963, issuerKeyID: nil,
            kind: kind ?? .ca(permittedDNS: ["localhost"]))
        let tbs = X509Builder.tbs(spec)
        return X509Builder.certificate(tbs: tbs, signature: try X509Builder.sign(tbs, with: signer))
    }

    @Test func restoreRefusesAKeyWithATamperedPrivateHalf() throws {
        let ca = try LocalCA.create(permitted: ["localhost"])
        var key = try ca.keyX963()
        // The public half is the one of the certificate, but D is not the private key of it.
        key[key.count - 1] ^= 0x01
        #expect(throws: LocalCA.Failure.keyMismatch) { try LocalCA.restore(certificateDER: ca.der, keyX963: key) }
    }

    @Test func restoreRefusesACertificateWithABadSelfSignature() throws {
        let ca = try LocalCA.create(permitted: ["localhost"])
        let other = try LocalCA.newKey()
        let forged = try certificate(subject: ca.key, signer: other)
        #expect(throws: LocalCA.Failure.certificate) {
            try LocalCA.restore(certificateDER: forged, keyX963: try ca.keyX963())
        }
        // The same certificate with its own key signs well.
        let good = try certificate(subject: ca.key, signer: ca.key)
        #expect((try? LocalCA.restore(certificateDER: good, keyX963: try ca.keyX963())) != nil)
    }

    @Test func restoreRefusesACertificateThatIsNotACA() throws {
        let key = try LocalCA.newKey()
        let der = try certificate(subject: key, signer: key, kind: .leaf(dnsNames: ["localhost"]))
        let ca = try LocalCA.restore(
            certificateDER: try certificate(subject: key, signer: key), keyX963: Self.x963(key))
        #expect(ca.permitted == ["localhost"])
        #expect(throws: LocalCA.Failure.certificate) {
            try LocalCA.restore(certificateDER: der, keyX963: try Self.x963(key))
        }
    }

    @Test func restoreRefusesAnIssuerThatIsNotTheSubject() throws {
        let key = try LocalCA.newKey()
        let der = try certificate(
            subject: key, signer: key, issuerName: X509Builder.name(cn: "Someone else", organization: nil))
        #expect(throws: LocalCA.Failure.certificate) {
            try LocalCA.restore(certificateDER: der, keyX963: try Self.x963(key))
        }
    }

    @Test func restoreRefusesAnExpiredOrNotYetValidCertificate() throws {
        let ca = try LocalCA.create(permitted: ["localhost"])
        let info = try #require(X509Builder.readCA(certificateDER: ca.der))
        let key = try ca.keyX963()
        #expect(throws: LocalCA.Failure.certificate) {
            try LocalCA.restore(certificateDER: ca.der, keyX963: key, now: info.notAfter.addingTimeInterval(60))
        }
        #expect(throws: LocalCA.Failure.certificate) {
            try LocalCA.restore(certificateDER: ca.der, keyX963: key, now: info.notBefore.addingTimeInterval(-day))
        }
        #expect(
            (try? LocalCA.restore(certificateDER: ca.der, keyX963: key, now: info.notAfter.addingTimeInterval(-60)))
                != nil)
    }

    @Test func aCAOnlyCoversTheSuffixesItPermits() throws {
        let ca = try LocalCA.create(permitted: ["localhost", "colima.internal"])
        #expect(ca.covers(["localhost"]) && ca.covers(["colima.internal", "localhost"]) && ca.covers([]))
        #expect(!ca.covers(["localhost", "other.test"]))
        let narrow = try LocalCA.create(permitted: ["localhost"])
        #expect(!narrow.covers(["colima.internal", "localhost"]))
    }

    private static func x963(_ key: SecKey) throws -> [UInt8] {
        var error: Unmanaged<CFError>?
        let data = try #require(SecKeyCopyExternalRepresentation(key, &error) as Data?)
        return [UInt8](data)
    }
}
