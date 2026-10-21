import Foundation
import Security
import Testing

@testable import ColimaBar

/// These tests read only. No test calls `TrustStore.install` or `remove`:
/// they change the login keychain and the trust settings of the user.
@Suite struct TrustStoreTests {
    @Test func theTrustSettingsAreForTheSSLPolicyAndTrustTheCertificateAsARoot() throws {
        let settings = TrustStore.trustSettings() as? [[String: Any]]
        let one = try #require(settings?.first)
        #expect(settings?.count == 1)
        let policy = try #require(one[kSecTrustSettingsPolicy as String]) as! SecPolicy
        let properties = SecPolicyCopyProperties(policy) as? [String: Any]
        #expect(properties?[kSecPolicyOid as String] as? String == kSecPolicyAppleSSL as String)
        #expect(one[kSecTrustSettingsResult as String] as? UInt32 == SecTrustSettingsResult.trustRoot.rawValue)
        // No application, no policy string and no key usage: nothing narrows or widens the SSL policy.
        #expect(Set(one.keys) == [kSecTrustSettingsPolicy as String, kSecTrustSettingsResult as String])
    }

    @Test func aNewCAIsNotTrusted() throws {
        let ca = try LocalCA.create(permitted: ["localhost"])
        #expect(!TrustStore.isTrusted(ca))
    }
}
