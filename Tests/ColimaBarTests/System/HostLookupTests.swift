import Testing

@testable import ColimaBar

@Suite struct HostLookupTests {
    @Test func theLocalHostNameResolves() async {
        #expect(await HostLookup.resolves("localhost"))
    }

    @Test func anIPv4AddressResolves() async {
        #expect(await HostLookup.resolves("127.0.0.1"))
    }

    @Test func anEmptyNameDoesNotResolve() async {
        #expect(await !HostLookup.resolves(""))
    }
}
