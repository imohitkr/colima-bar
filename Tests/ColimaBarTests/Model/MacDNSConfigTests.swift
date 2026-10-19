import Testing

@testable import ColimaBar

@Suite struct MacDNSConfigTests {
    private let global: [String: Any] = ["ServerAddresses": ["192.0.2.1", "192.0.2.2"], "DomainName": "example.net"]
    private let vpn: [String: Any] = [
        "ServerAddresses": ["198.51.100.7"], "SupplementalMatchDomains": ["corp.example", "lab.example"],
    ]
    private let wifi: [String: Any] = ["ServerAddresses": ["192.0.2.1"]]

    @Test func theGlobalServersKeepTheirOrder() {
        let c = MacDNSConfig.parse(global: global, services: [:])
        #expect(c.servers == ["192.0.2.1", "192.0.2.2"])
        #expect(c.splitDomains.isEmpty)
    }

    @Test func aServiceWithMatchDomainsGivesSplitDomains() {
        let c = MacDNSConfig.parse(
            global: global, services: ["State:/Network/Service/A/DNS": wifi, "State:/Network/Service/B/DNS": vpn])
        #expect(c.splitDomains == ["corp.example", "lab.example"])
    }

    @Test func anEmptyMatchDomainAndReverseZonesAreNotSplitDomains() {
        let service: [String: Any] = ["SupplementalMatchDomains": ["", "10.in-addr.arpa", "local", "Corp.Example"]]
        let c = MacDNSConfig.parse(global: nil, services: ["k": service])
        #expect(c.splitDomains == ["Corp.Example"])
    }

    @Test func noInputGivesAnEmptySetupWithAFingerprint() {
        let c = MacDNSConfig.parse(global: nil, services: [:])
        #expect(c.servers.isEmpty && c.splitDomains.isEmpty && !c.fingerprint.isEmpty)
    }

    @Test func theFingerprintDoesNotDependOnTheOrderOfTheServices() {
        let a = MacDNSConfig.parse(global: global, services: ["x": wifi, "y": vpn, "z": [:]])
        let b = MacDNSConfig.parse(global: global, services: ["z": [:], "y": vpn, "x": wifi])
        #expect(a.fingerprint == b.fingerprint)
    }

    @Test func theFingerprintChangesWithAServerADomainOrAService() {
        let base = MacDNSConfig.parse(global: global, services: ["x": wifi]).fingerprint
        let otherServer: [String: Any] = ["ServerAddresses": ["192.0.2.9"]]
        #expect(MacDNSConfig.parse(global: otherServer, services: ["x": wifi]).fingerprint != base)
        #expect(MacDNSConfig.parse(global: global, services: ["x": vpn]).fingerprint != base)
        #expect(MacDNSConfig.parse(global: global, services: ["x": wifi, "y": wifi]).fingerprint != base)
    }

    @Test func theFingerprintHoldsNoAddressAndNoName() {
        let c = MacDNSConfig.parse(global: global, services: ["x": vpn])
        #expect(!c.fingerprint.contains("192") && !c.fingerprint.contains("corp"))
        #expect(c.fingerprint.count == 16)
    }

    @Test func wrongTypesAreIgnored() {
        let bad: [String: Any] = ["ServerAddresses": "192.0.2.1", "SupplementalMatchDomains": [1, 2]]
        let c = MacDNSConfig.parse(global: bad, services: ["x": bad])
        #expect(c.servers.isEmpty && c.splitDomains.isEmpty)
    }
}
