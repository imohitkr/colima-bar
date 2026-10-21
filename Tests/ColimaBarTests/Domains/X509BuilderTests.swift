import Foundation
import Security
import Testing

@testable import ColimaBar

@Suite struct X509BuilderTests {
    private let day: TimeInterval = 86400

    private func hex(_ s: String) -> [UInt8] {
        stride(from: 0, to: s.count, by: 2).map {
            UInt8(s[s.index(s.startIndex, offsetBy: $0)..<s.index(s.startIndex, offsetBy: $0 + 2)], radix: 16) ?? 0
        }
    }

    private func spec(permitted: [String] = ["localhost"]) -> X509Builder.Spec {
        let issuer = X509Builder.name(cn: "Test CA", organization: "Test")
        return X509Builder.Spec(
            serial: [UInt8](repeating: 0x11, count: 16), subjectCN: "Test CA", organization: "Test", issuerName: issuer,
            notBefore: Date(timeIntervalSince1970: 1_800_000_000), notAfter: Date(timeIntervalSince1970: 1_900_000_000),
            publicKeyX963: [0x04] + [UInt8](repeating: 0x22, count: 64), issuerKeyID: nil,
            kind: .ca(permittedDNS: permitted))
    }

    @Test func theTBSIsTheSameForTheSameSpec() {
        let a = X509Builder.tbs(spec())
        #expect(a == X509Builder.tbs(spec()))
        var other = spec()
        other.serial[0] = 0x12
        #expect(a != X509Builder.tbs(other))
        #expect(a != X509Builder.tbs(spec(permitted: ["localhost", "colima.internal"])))
    }

    @Test func theNameConstraintsHaveTheDNSNamesAndExcludeEveryAddress() {
        let expected: [UInt8] =
            hex("3041" + "A00D" + "300B" + "8209" + "6C6F63616C686F7374" + "A130")
            + hex("300A" + "8708" + String(repeating: "00", count: 8))
            + hex("3022" + "8720" + String(repeating: "00", count: 32))
        #expect(X509Builder.nameConstraints(permittedDNS: ["localhost"]) == expected)
        // The extension: OID, critical, then the value in an OCTET STRING.
        let extensionBytes = hex("304D" + "0603551D1E" + "0101FF" + "0443") + expected
        let all = X509Builder.extensions(spec()).first { $0.starts(with: hex("304D0603551D1E")) }
        #expect(all == extensionBytes)
    }

    @Test func theTBSHoldsTheConstraintsOnce() {
        let tbs = X509Builder.tbs(spec())
        let needle = X509Builder.nameConstraints(permittedDNS: ["localhost"])
        var found = 0
        for start in 0..<(tbs.count - needle.count + 1) where Array(tbs[start..<(start + needle.count)]) == needle {
            found += 1
        }
        #expect(found == 1)
    }

    @Test func aCAHasTheExtensionsOfAConstrainedServerCA() throws {
        let ca = try LocalCA.create(permitted: ["localhost"])
        let oids = try #require(extensionOIDs(ca.der))
        #expect(oids == ["2.5.29.19", "2.5.29.15", "2.5.29.30", "2.5.29.37", "2.5.29.14"])
        #expect(X509Builder.permittedDNS(certificateDER: ca.der) == ["localhost"])
    }

    @Test func aRandomSerialHasATopBitOfZeroAndIsNotZero() {
        for _ in 0..<50 {
            let serial = X509Builder.randomSerial()
            #expect(serial.count == 16 && serial[0] & 0x80 == 0 && serial.contains { $0 != 0 })
        }
    }

    @Test func theCertificateRoundTripsThroughSecurity() throws {
        let ca = try LocalCA.create(permitted: ["localhost"])
        let cert = try #require(SecCertificateCreateWithData(nil, Data(ca.der) as CFData))
        #expect(SecCertificateCopySubjectSummary(cert) as String? == ca.commonName)
        #expect(ca.commonName.hasPrefix("ColimaBar Local CA "))
        let key = try #require(SecCertificateCopyKey(cert))
        #expect(try LocalCA.publicX963(of: key) == ca.publicX963)
        // The DER that the builder makes is the DER that Security reads.
        #expect([UInt8](SecCertificateCopyData(cert) as Data) == ca.der)
    }

    @Test func pemHasBase64Lines() {
        let pem = X509Builder.pem(Array(repeating: 1, count: 100))
        #expect(pem.hasPrefix("-----BEGIN CERTIFICATE-----\n") && pem.hasSuffix("-----END CERTIFICATE-----\n"))
        #expect(pem.split(separator: "\n").dropFirst().dropLast().allSatisfy { $0.count <= 64 })
    }

    // MARK: - Trust evaluation. The CA is the only anchor: no trust setting changes.

    private func trusted(_ leaf: SecCertificate, host: String, anchor: LocalCA, at date: Date = Date()) -> Bool {
        var trust: SecTrust?
        guard SecTrustCreateWithCertificates(leaf, SecPolicyCreateSSL(true, host as CFString), &trust) == errSecSuccess,
            let trust
        else { return false }
        SecTrustSetAnchorCertificates(trust, [anchor.certificate] as CFArray)
        SecTrustSetAnchorCertificatesOnly(trust, true)
        SecTrustSetVerifyDate(trust, date as CFDate)
        return SecTrustEvaluateWithError(trust, nil)
    }

    private func leaf(
        _ ca: LocalCA, names: [String], ips: [[UInt8]] = [], from: Date = Date().addingTimeInterval(-3600),
        to: Date = Date().addingTimeInterval(30 * 86400)
    ) throws -> SecCertificate {
        let key = try LocalCA.newKey()
        let x963 = try LocalCA.publicX963(of: key)
        let spec = X509Builder.Spec(
            serial: X509Builder.randomSerial(), subjectCN: names.first ?? "x", organization: nil,
            issuerName: ca.name, notBefore: from, notAfter: to, publicKeyX963: x963, issuerKeyID: ca.keyID,
            kind: .leaf(dnsNames: names, ipAddresses: ips))
        let tbs = X509Builder.tbs(spec)
        let der = X509Builder.certificate(tbs: tbs, signature: try X509Builder.sign(tbs, with: ca.key))
        return try #require(SecCertificateCreateWithData(nil, Data(der) as CFData))
    }

    @Test func aLeafUnderLocalhostIsTrustedAndAForeignNameIsNot() throws {
        let ca = try LocalCA.create(permitted: ["localhost"])
        let web = try leaf(ca, names: ["web.shop.localhost"])
        #expect(trusted(web, host: "web.shop.localhost", anchor: ca))
        #expect(!trusted(web, host: "other.localhost", anchor: ca))  // the name does not match
        let local = try leaf(ca, names: ["localhost"])
        #expect(trusted(local, host: "localhost", anchor: ca))
        #expect(!trusted(try leaf(ca, names: ["www.example.com"]), host: "www.example.com", anchor: ca))
    }

    @Test func aNameUnderACustomSuffixNeedsThatSuffixInTheConstraints() throws {
        let both = try LocalCA.create(permitted: ["localhost", "colima.internal"])
        let only = try LocalCA.create(permitted: ["localhost"])
        let name = "web.shop.colima.internal"
        #expect(trusted(try leaf(both, names: [name]), host: name, anchor: both))
        #expect(!trusted(try leaf(only, names: [name]), host: name, anchor: only))
        #expect(!trusted(try leaf(both, names: ["evil.internal"]), host: "evil.internal", anchor: both))
    }

    @Test func aNameThatOnlyEndsInTheSuffixLettersIsRejected() throws {
        let ca = try LocalCA.create(permitted: ["localhost"])
        for name in ["evillocalhost", "notlocalhost", "localhost.evil.com", "localhostx"] {
            #expect(!trusted(try leaf(ca, names: [name]), host: name, anchor: ca), "\(name)")
        }
        #expect(trusted(try leaf(ca, names: ["a.localhost"]), host: "a.localhost", anchor: ca))
    }

    @Test func aSANWithAnEmptyLabelIsRejected() throws {
        let ca = try LocalCA.create(permitted: ["localhost"])
        for name in [".localhost", "a..localhost", "..localhost"] {
            #expect(!trusted(try leaf(ca, names: [name]), host: name, anchor: ca), "\(name)")
        }
    }

    @Test func aSANInUpperCaseIsTrustedLikeItsLowerCaseName() throws {
        // DNS names are not case sensitive. The proxy sends lower case names only (`LeafCache.mintName`).
        let ca = try LocalCA.create(permitted: ["localhost"])
        let upper = try leaf(ca, names: ["WEB.LOCALHOST"])
        #expect(trusted(upper, host: "web.localhost", anchor: ca) == trusted(upper, host: "WEB.LOCALHOST", anchor: ca))
    }

    @Test func aLeafWithAnIPAddressIsRejected() throws {
        let ca = try LocalCA.create(permitted: ["localhost"])
        let withIP = try leaf(ca, names: ["web.localhost"], ips: [[127, 0, 0, 1]])
        #expect(!trusted(withIP, host: "127.0.0.1", anchor: ca))
        // The IP in the SAN makes the whole certificate invalid under this CA.
        #expect(!trusted(withIP, host: "web.localhost", anchor: ca))
        let v6 = try leaf(ca, names: ["web.localhost"], ips: [[UInt8](repeating: 0, count: 15) + [1]])
        #expect(!trusted(v6, host: "::1", anchor: ca))
    }

    @Test func anExpiredOrNotYetValidLeafIsRejected() throws {
        let ca = try LocalCA.create(permitted: ["localhost"])
        let expired = try leaf(
            ca, names: ["a.localhost"], from: Date().addingTimeInterval(-3 * day), to: Date().addingTimeInterval(-day))
        #expect(!trusted(expired, host: "a.localhost", anchor: ca))
        let future = try leaf(
            ca, names: ["a.localhost"], from: Date().addingTimeInterval(day), to: Date().addingTimeInterval(3 * day))
        #expect(!trusted(future, host: "a.localhost", anchor: ca))
    }

    @Test func aLeafOfAnotherCAIsRejected() throws {
        let ca = try LocalCA.create(permitted: ["localhost"])
        let other = try LocalCA.create(permitted: ["localhost"])
        #expect(!trusted(try leaf(other, names: ["a.localhost"]), host: "a.localhost", anchor: ca))
    }

    // MARK: -

    /// The OIDs of the extensions of a certificate, as dotted text.
    private func extensionOIDs(_ der: [UInt8]) -> [String]? {
        guard let cert = DER.read(der[...]), let top = DER.children(cert.content), let tbs = top.first,
            let fields = DER.children(tbs.content), let wrapper = fields.first(where: { $0.tag == 0xA3 }),
            let list = DER.read(wrapper.content), let extensions = DER.children(list.content)
        else { return nil }
        return extensions.compactMap { e in
            guard let parts = DER.children(e.content), let id = parts.first else { return nil }
            return dotted(Array(id.content))
        }
    }

    private func dotted(_ bytes: [UInt8]) -> String {
        guard let first = bytes.first else { return "" }
        var parts = [Int(first) / 40, Int(first) % 40]
        var value = 0
        for b in bytes.dropFirst() {
            value = value << 7 | Int(b & 0x7F)
            if b & 0x80 == 0 {
                parts.append(value)
                value = 0
            }
        }
        return parts.map(String.init).joined(separator: ".")
    }
}
