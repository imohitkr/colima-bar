import Foundation
import Testing

@testable import ColimaBar

@Suite struct AfterSleepCheckTests {
    private func row(_ name: String, running: Bool = true, runtime: String = "docker") -> ProfileRow {
        ProfileRow(name: name, isRunning: running, cpus: 2, memGB: 2, runtime: runtime)
    }

    @Test func onlyRunningDockerProfilesWithValidNamesAreChecked() {
        let rows = [
            row("default"), row("work"), row("old", runtime: ""), row("ctrd", runtime: "containerd"),
            row("down", running: false), row("bad name"),
        ]
        #expect(AfterSleepCheck.profiles(rows, blocked: []) == ["default", "work", "old"])
    }

    @Test func blockedProfilesAreSkipped() {
        let rows = [row("default"), row("work")]
        #expect(AfterSleepCheck.profiles(rows, blocked: ["work"]) == ["default"])
    }

    @Test func pingDelaysRiseAndEndWithinFifteenSeconds() {
        let delays = AfterSleepCheck.pingDelays
        #expect(delays.first == .zero)
        #expect(delays == delays.sorted())
        #expect(delays.reduce(Duration.zero, +) <= .seconds(15))
    }

    @Test func textsNameTheProfile() {
        let noAnswer = AfterSleepCheck.noAnswerText(profile: "work")
        #expect(noAnswer.contains("work"))
        #expect(noAnswer.hasSuffix("Click Restart to restart the VM."))
        let behind = AfterSleepCheck.clockText(profile: "work", offset: -37.25)
        #expect(behind.contains("work"))
        #expect(behind.contains("37 seconds behind"))
        let ahead = AfterSleepCheck.clockText(profile: "work", offset: 5)
        #expect(ahead.contains("5 seconds ahead of"))
        #expect(behind.contains("the Mac. ColimaBar could not set it. Click Restart to restart the VM."))
    }

    @Test func restartRefusalsNameTheProfile() {
        #expect(AfterSleepCheck.restartMissingText(profile: "work").contains("work"))
        #expect(AfterSleepCheck.restartBusyText(profile: "work").contains("work"))
        #expect(AfterSleepCheck.restartStoppedText(profile: "work").contains("work"))
    }
}
