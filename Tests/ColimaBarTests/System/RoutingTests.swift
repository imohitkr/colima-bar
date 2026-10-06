import Foundation
import Testing

@testable import ColimaBar

@Suite struct RoutingTests {
    @Test func matchesEqualsWithoutSpaces() {
        #expect(Routing.dockerHostValue("docker.host=unix:///tmp/a.sock") == "unix:///tmp/a.sock")
    }

    @Test func matchesEqualsWithSpaces() {
        #expect(Routing.dockerHostValue("docker.host = tcp://remote:2375") == "tcp://remote:2375")
    }

    @Test func matchesColonSeparator() {
        #expect(Routing.dockerHostValue("docker.host:tcp://remote:2375") == "tcp://remote:2375")
        #expect(Routing.dockerHostValue("docker.host : tcp://remote:2375") == "tcp://remote:2375")
    }

    @Test func matchesLeadingWhitespace() {
        #expect(Routing.dockerHostValue("   docker.host=tcp://remote:2375") == "tcp://remote:2375")
        #expect(Routing.dockerHostValue("\tdocker.host=tcp://remote:2375  ") == "tcp://remote:2375")
    }

    @Test func ignoresCommentsAndOtherKeys() {
        #expect(Routing.dockerHostValue("#docker.host=tcp://remote:2375") == nil)
        #expect(Routing.dockerHostValue("  # docker.host=tcp://remote:2375") == nil)
        #expect(Routing.dockerHostValue("docker.hostname=foo") == nil)
        #expect(Routing.dockerHostValue("ryuk.disabled=true") == nil)
        #expect(Routing.dockerHostValue("docker.host") == nil)
    }

    @Test func whitespaceAloneSeparatesKeyAndValue() {
        #expect(Routing.dockerHostValue("docker.host tcp://remote:2375") == "tcp://remote:2375")
        #expect(Routing.dockerHostValue("docker.host\ttcp://remote:2375") == "tcp://remote:2375")
        #expect(Routing.dockerHostValue("  docker.host   unix:///tmp/a.sock\r") == "unix:///tmp/a.sock")
    }

    @Test func whitespaceThenSeparatorStillWorks() {
        #expect(Routing.dockerHostValue("docker.host   =  tcp://remote:2375") == "tcp://remote:2375")
        #expect(Routing.dockerHostValue("docker.host  :tcp://remote:2375") == "tcp://remote:2375")
    }

    @Test func otherKeysDoNotMatch() {
        #expect(Routing.dockerHostValue("docker.hostname tcp://remote:2375") == nil)
        #expect(Routing.dockerHostValue("docker.hostname=foo") == nil)
        #expect(Routing.dockerHostValue("docker.host") == nil)
        #expect(Routing.dockerHostValue("# docker.host tcp://remote:2375") == nil)
    }
}
