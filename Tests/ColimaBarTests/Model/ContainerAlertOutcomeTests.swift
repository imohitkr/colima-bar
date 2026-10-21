import Testing

@testable import ColimaBar

@Suite struct ContainerAlertOutcomeTests {
    @Test func textsAreExact() {
        #expect(ContainerAlertOutcome.oom.body == "Killed: out of memory")
        #expect(ContainerAlertOutcome.crash(code: "2").body == "Exited with code 2")
        #expect(ContainerAlertOutcome.unhealthy.body == "Healthcheck is failing")
        #expect(ContainerAlertOutcome.recovered.body == "Healthy again")
        #expect(
            ContainerAlertOutcome.loop(count: 3, lastCode: "1").body
                == "Keeps restarting: 3 exits in 5 minutes. Last exit code 1.")
        #expect(
            ContainerAlertOutcome.loop(count: 3, lastCode: nil).body == "Keeps restarting: 3 exits in 5 minutes.")
    }

    @Test func onlyRecoveryIsARecovery() {
        #expect(ContainerAlertOutcome.recovered.isRecovery)
        #expect(!ContainerAlertOutcome.unhealthy.isRecovery)
        #expect(!ContainerAlertOutcome.loop(count: 3, lastCode: nil).isRecovery)
    }

    @Test func loopTextsShareOneThrottleKey() {
        let a = ContainerAlertOutcome.loop(count: 3, lastCode: "1").body
        let b = ContainerAlertOutcome.loop(count: 4, lastCode: "2").body
        #expect(AlertThrottle.key(container: "x", body: a) == AlertThrottle.key(container: "x", body: b))
    }
}
