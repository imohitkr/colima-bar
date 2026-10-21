import Testing

@testable import ColimaBar

@Suite struct DomainStatusTests {
    @Test func offHasNoCaption() {
        #expect(DomainStatus().caption(routeCount: 3) == nil)
    }

    @Test func startingAndDebug() {
        #expect(DomainStatus(phase: .starting).caption(routeCount: 0) == "Starting the proxy…")
        #expect(DomainStatus(phase: .debugRun).caption(routeCount: 0) == Help.domainsDebug)
    }

    @Test func runningOnPort80CountsTheNames() {
        let s = DomainStatus(phase: .running, httpPort: 80)
        #expect(!s.usesFallback)
        #expect(s.caption(routeCount: 1) == "The proxy listens on port 80. 1 container has a name.")
        #expect(s.caption(routeCount: 4) == "The proxy listens on port 80. 4 containers have a name.")
        #expect(s.caption(routeCount: 0) == "The proxy listens on port 80. 0 containers have a name.")
    }

    @Test func port8080IsTheFallback() {
        let s = DomainStatus(phase: .running, httpPort: 8080)
        #expect(s.usesFallback)
        #expect(s.caption(routeCount: 2) == "Port 80 is busy, so the proxy listens on port 8080.")
    }

    @Test func aFailureShowsItsProblem() {
        let s = DomainStatus(phase: .failed, problem: "Ports 80 and 8080 are busy.")
        #expect(s.caption(routeCount: 0) == "Ports 80 and 8080 are busy.")
        #expect(DomainStatus(phase: .failed).caption(routeCount: 0) == "The proxy could not start.")
    }
}
