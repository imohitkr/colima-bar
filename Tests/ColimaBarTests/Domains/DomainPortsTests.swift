import Testing

@testable import ColimaBar

@Suite struct DomainPortsTests {
    @Test func theProxyTriesPort80First() {
        #expect(DomainPorts.http == [80, 8080])
    }

    @Test func theHTTPSListenerTries443Then8443() {
        #expect(DomainPorts.https == [443, 8443])
        #expect(DomainPorts.candidates(DomainPorts.https, published: [443]) == [8443])
    }

    @Test func candidatesLeaveOutPublishedPorts() {
        #expect(DomainPorts.candidates([80, 8080], published: []) == [80, 8080])
        #expect(DomainPorts.candidates([80, 8080], published: [80]) == [8080])
        #expect(DomainPorts.candidates([80, 8080], published: [80, 8080, 3000]) == [])
    }

    @Test func tlsPortsAreTheOnesOfPortLink() {
        #expect(DomainPorts.tlsContainerPorts == [443, 8443])
        #expect(DomainPorts.preferred.last == 8443)
    }
}
