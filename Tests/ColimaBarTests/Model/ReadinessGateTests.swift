import Foundation
import Testing

@testable import ColimaBar

@Suite struct ReadinessGateTests {
    /// A probe with a script of answers, and a clock that only `sleep` moves.
    /// `@unchecked Sendable`: the tests call it from one task.
    private final class Fake: @unchecked Sendable {
        var answers: [Bool]
        var probes = 0
        var clock = TestInstants()
        init(_ answers: [Bool]) { self.answers = answers }

        func probe() async -> Bool {
            probes += 1
            return answers.isEmpty ? false : answers.removeFirst()
        }
    }

    private func wait(_ fake: Fake, streak: Int = 3, timeout: TimeInterval = 60) async -> Bool {
        await ReadinessGate.wait(
            probe: { await fake.probe() }, streak: streak, timeout: timeout, interval: .seconds(1),
            now: { fake.clock.now }, sleep: { _ in fake.clock.advance(1) })
    }

    @Test func dockerIsReadyAfterThreeGoodProbesInARow() async {
        let fake = Fake([true, true, true])
        #expect(await wait(fake))
        #expect(fake.probes == 3)
    }

    @Test func aFailedProbeStartsTheCountAgain() async {
        let fake = Fake([true, true, false, true, true, true])
        #expect(await wait(fake))
        #expect(fake.probes == 6)
    }

    @Test func theGateGivesUpWhenTheTimeIsOver() async {
        let fake = Fake([])
        #expect(await wait(fake, timeout: 10) == false)
        #expect(fake.probes == 10)  // one probe for each second of the clock
    }

    @Test func aCancelledTaskStopsTheGateAfterTheProbeInFlight() async {
        let fake = Fake([])
        let task = Task {
            await ReadinessGate.wait(
                probe: {
                    withUnsafeCurrentTask { $0?.cancel() }  // the user presses Ctrl-C during the probe
                    return await fake.probe()
                }, streak: 3, timeout: 1000, interval: .seconds(1), now: { fake.clock.now },
                sleep: { _ in fake.clock.advance(1) })
        }
        #expect(await task.value == false)
        #expect(fake.probes == 1)
    }

    @Test func tooFewGoodProbesBeforeTheTimeIsOverFail() async {
        let fake = Fake([true, true])
        #expect(await wait(fake, timeout: 10) == false)
    }

    @Test func theDefaultsAreTheOnesOfTheWake() {
        #expect(ReadinessGate.streak == 3)
        #expect(ReadinessGate.timeout == 60)
        #expect(ReadinessGate.interval == .milliseconds(500))
    }

    @Test func theProbeAsksContainerdForAnImageThatDoesNotExist() {
        #expect(ReadinessGate.probePath.hasPrefix("/images/json?filters="))
        #expect(ReadinessGate.probePath.removingPercentEncoding?.contains("colimabar-readiness-probe") == true)
    }

    @Test func theDockerProbeFailsWhenNothingListens() async {
        let probe = ReadinessGate.dockerProbe(socketPath: TestSocketPath.unique())
        #expect(await probe() == false)
    }

    @Test func theDockerProbeSucceedsWhenTheDaemonAnswers() async throws {
        let path = TestSocketPath.unique()
        let daemon = FakeDaemon(path: path)
        try daemon.start()
        defer { daemon.stop() }
        let probe = ReadinessGate.dockerProbe(socketPath: path)
        #expect(await probe())
        #expect(daemon.seen.first?.contains("GET /images/json") == true)
    }
}
