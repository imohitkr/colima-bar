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

    // MARK: HTTPS

    private func https(_ phase: DomainStatus.HTTPS.Phase, port: UInt16? = nil, problem: String? = nil)
        -> DomainStatus.HTTPS
    {
        .init(phase: phase, port: port, problem: problem)
    }

    @Test func httpsCaptions() {
        #expect(https(.off).caption == nil)
        #expect(
            https(.off, problem: "You cancelled the password dialog. HTTPS stays off.").caption
                == "You cancelled the password dialog. HTTPS stays off.")
        #expect(https(.settingUp).caption == "Setting up HTTPS…")
        #expect(https(.removing).caption == "Removing the certificate authority…")
        #expect(https(.running, port: 443).caption == "HTTPS listens on port 443.")
        #expect(https(.running, port: 8443).caption == "Port 443 is busy, so HTTPS listens on port 8443.")
        #expect(
            https(.untrusted, port: 443).caption
                == "macOS does not trust the certificate authority. Browsers show a warning.")
        #expect(
            https(.failed, problem: "Ports 443 and 8443 are busy.").caption
                == "HTTPS could not start. Ports 443 and 8443 are busy.")
        #expect(https(.failed).caption == "HTTPS could not start.")
    }

    @Test func httpsListensInTwoPhasesAndKnowsItsFallback() {
        #expect(https(.running, port: 443).listening && https(.untrusted, port: 443).listening)
        for phase in [DomainStatus.HTTPS.Phase.off, .settingUp, .failed, .removing] {
            #expect(!https(phase, port: 443).listening)
        }
        #expect(!https(.running, port: 443).usesFallback)
        #expect(https(.running, port: 8443).usesFallback)
        #expect(!https(.off).usesFallback)
    }

    @Test func theHTTPPartAndTheHTTPSPartAreIndependent() {
        var s = DomainStatus(phase: .running, httpPort: 80)
        s.https = https(.running, port: 443)
        #expect(s.caption(routeCount: 1) == "The proxy listens on port 80. 1 container has a name.")
        #expect(s.https.caption == "HTTPS listens on port 443.")
        #expect(DomainStatus().https == DomainStatus.HTTPS())
    }
}
