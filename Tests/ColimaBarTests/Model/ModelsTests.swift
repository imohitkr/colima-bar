import Foundation
import Testing

@testable import ColimaBar

@Suite struct ModelsTests {
    /// The reference implementation: the parser that ran on every read before
    /// health became stored.
    private func referenceHealth(_ status: String) -> String? {
        for h in ["unhealthy", "healthy", "health: starting"] where status.contains("(\(h))") { return h }
        return nil
    }

    private func ctr(_ status: String, state: String = "running") -> Container {
        Container(id: "x", name: "x", image: "i", state: state, status: status, ports: [], project: nil)
    }

    @Test func matchesReferenceImplementation() {
        for status in [
            "Up 2 hours (healthy)", "Up 1 minute (unhealthy)", "Up 5 seconds (health: starting)",
            "Up 3 days", "Exited (1) 2 minutes ago", "Created", "", "Up 1 hour (Paused)",
            "Up 4 minutes (healthy) (unhealthy)",
        ] {
            #expect(ctr(status).health == referenceHealth(status), "\(status)")
            #expect(Container.health(status: status) == referenceHealth(status), "\(status)")
        }
    }

    @Test func eachStatusMapsToItsHealth() {
        #expect(ctr("Up 2 hours (healthy)").health == "healthy")
        #expect(ctr("Up 1 minute (unhealthy)").health == "unhealthy")
        #expect(ctr("Up 5 seconds (health: starting)").health == "health: starting")
        #expect(ctr("Up 3 days").health == nil)
    }

    @Test func theNamedVolumesLeaveOutAnonymousOnesAndAreSortedByName() {
        func row(_ name: String, anonymous: Bool = false) -> VolumeRow {
            VolumeRow(name: name, size: 1, links: 0, project: nil, isAnonymous: anonymous)
        }
        let rows = [row("b"), row(String(repeating: "f", count: 64), anonymous: true), row("a")]
        #expect(VolumeRow.named(rows).map(\.name) == ["a", "b"])
    }
}
