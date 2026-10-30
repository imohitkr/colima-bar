import Foundation
import Testing

@testable import ColimaBar

@MainActor @Suite struct ColimaModelContainersListedTests {
    private func daemon(status: Int = 200) throws -> FakeDaemon {
        let d = FakeDaemon(path: TestSocketPath.unique()) { _ in
            (status, Data(#"[{"Id":"c1","Names":["/c1"],"Image":"nginx","State":"running","Status":"Up"}]"#.utf8))
        }
        try d.start()
        return d
    }

    private func model(_ d: FakeDaemon) -> ColimaModel {
        let m = ColimaModel(profile: "listed-test-profile", readOnly: true, dockerAPI: DockerAPI(socketPath: d.path))
        m.setState(.running)
        return m
    }

    @Test func theCounterRisesWithEachListAndClearsOnAStop() async throws {
        let d = try daemon()
        defer { d.stop() }
        let m = model(d)
        #expect(m.containersListed == 0)
        #expect(await m.refreshContainers())
        #expect(m.containersListed == 1)
        #expect(await m.refreshContainers())
        #expect(m.containersListed == 2)
        m.clearVMData(because: .vmStopped)
        #expect(m.containersListed == 0)
    }

    @Test func aFailedListLeavesTheCounter() async throws {
        let d = try daemon(status: 500)
        defer { d.stop() }
        let m = model(d)
        #expect(await m.refreshContainers() == false)
        #expect(m.containersListed == 0)
    }
}
