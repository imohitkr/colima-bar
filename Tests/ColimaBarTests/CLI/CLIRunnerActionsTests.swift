import Foundation
import Testing

@testable import ColimaBar

/// The decisions behind `start`, `stop`, `restart` and `open`. The tests
/// give each decision its input. They start no VM and no app.
@MainActor @Suite struct CLIRunnerActionsTests {
    private func row(_ status: String, runtime: String? = "docker") -> CLIStatus.Row {
        CLIStatus.Row(status: status, runtime: runtime, arch: nil, cpus: nil, memoryGiB: nil, diskGiB: nil)
    }

    @MainActor private final class Capture {
        var err: [String] = []
        var output: CLIOutput { CLIOutput(out: { _ in }, err: { self.err.append($0) }, isTerminal: true) }
    }

    /// A script of answers for the busy check, and a count of the pauses.
    @MainActor private final class Script {
        var answers: [String?]
        var checks = 0
        var sleeps = 0
        init(_ answers: [String?]) { self.answers = answers }
        func busy(_ profile: String) -> String? {
            checks += 1
            return answers.isEmpty ? nil : answers.removeFirst()
        }
    }

    // MARK: - The profile

    @Test func aProfileThatColimaDoesNotListIsUnknownUnlessItIsDefault() {
        let rows = ["default": row("Running")]
        #expect(CLIRunner.unknownProfileMessage("wrk", rows: rows)?.contains("The profile wrk does not exist") == true)
        #expect(CLIRunner.unknownProfileMessage("default", rows: [:]) == nil)
        #expect(CLIRunner.unknownProfileMessage("work", rows: ["work": row("Stopped")]) == nil)
    }

    // MARK: - Already done

    @Test func startingARunningProfileIsAlreadyDone() {
        let note = CLIRunner.alreadyDoneMessage(.start, profile: "work", rows: ["work": row("Running")])
        #expect(note == "The profile work is already running.")
    }

    @Test func startingAStoppedOrUnlistedProfileIsNotDone() {
        #expect(CLIRunner.alreadyDoneMessage(.start, profile: "work", rows: ["work": row("Stopped")]) == nil)
        #expect(CLIRunner.alreadyDoneMessage(.start, profile: "default", rows: [:]) == nil)
    }

    @Test func stoppingAStoppedProfileIsAlreadyDone() {
        let note = CLIRunner.alreadyDoneMessage(.stop, profile: "work", rows: ["work": row("Stopped")])
        #expect(note == "The profile work is already stopped.")
    }

    @Test func aProfileThatIsNotListedCountsAsStopped() {
        #expect(CLIRunner.alreadyDoneMessage(.stop, profile: "default", rows: [:]) != nil)
    }

    @Test func stoppingARunningProfileIsNotDone() {
        #expect(CLIRunner.alreadyDoneMessage(.stop, profile: "work", rows: ["work": row("Running")]) == nil)
    }

    @Test func aRestartIsNeverAlreadyDone() {
        for status in ["Running", "Stopped"] {
            #expect(CLIRunner.alreadyDoneMessage(.restart, profile: "work", rows: ["work": row(status)]) == nil)
        }
    }

    // MARK: - Readiness

    @Test func onlyTheDockerRuntimeWaitsForDocker() {
        #expect(CLIRunner.needsReadinessWait(runtime: "docker"))
        #expect(CLIRunner.needsReadinessWait(runtime: ""))
        #expect(!CLIRunner.needsReadinessWait(runtime: "containerd"))
        #expect(!CLIRunner.needsReadinessWait(runtime: "incus"))
    }

    // MARK: - The wait for other actions

    @Test func aFreeProfileDoesNotWait() async {
        let script = Script([nil])
        let result = await CLIRunner.waitForOtherActions(
            "work", output: Capture().output, busy: { script.busy($0) }, sleep: { _ in script.sleeps += 1 })
        #expect(result == .free)
        #expect(script.sleeps == 0)
    }

    @Test func theWaitEndsWhenTheOtherActionEnds() async {
        let script = Script(["Starting", "Starting", nil])
        let capture = Capture()
        let result = await CLIRunner.waitForOtherActions(
            "work", output: capture.output, busy: { script.busy($0) }, sleep: { _ in script.sleeps += 1 })
        #expect(result == .free)
        #expect(script.sleeps == 2)
        #expect(capture.err == ["Waiting for: Starting work"])  // said once for one label
    }

    @Test func aNewLabelIsSaidAgain() async {
        let script = Script(["Starting", "Stopping", nil])
        let capture = Capture()
        _ = await CLIRunner.waitForOtherActions(
            "work", output: capture.output, busy: { script.busy($0) }, sleep: { _ in })
        #expect(capture.err == ["Waiting for: Starting work", "Waiting for: Stopping work"])
    }

    @Test func theWaitTimesOutWhenTheActionDoesNotEnd() async {
        let script = Script(Array(repeating: "Starting", count: 10))
        let result = await CLIRunner.waitForOtherActions(
            "work", output: Capture().output, seconds: 3, busy: { script.busy($0) }, sleep: { _ in script.sleeps += 1 })
        #expect(result == .timedOut)
        #expect(script.checks == 3)
    }

    @Test func aCancelledTaskEndsTheWait() async {
        let script = Script(Array(repeating: "Starting", count: 10))
        let task = Task { @MainActor in
            await CLIRunner.waitForOtherActions(
                "work", output: Capture().output, busy: { script.busy($0) },
                sleep: { _ in withUnsafeCurrentTask { $0?.cancel() } })
        }
        #expect(await task.value == .cancelled)
        #expect(script.checks == 1)
    }

    @Test func aTextWithoutATerminalSaysNothingWhileItWaits() async {
        let script = Script(["Starting", nil])
        let capture = Capture()
        let quiet = CLIOutput(out: { _ in }, err: { capture.err.append($0) }, isTerminal: false)
        _ = await CLIRunner.waitForOtherActions("work", output: quiet, busy: { script.busy($0) }, sleep: { _ in })
        #expect(capture.err.isEmpty)
    }

    // MARK: - open

    @MainActor private final class Dashboard {
        var runningAnswers: [Bool]
        var opens = 0
        var sleeps = 0
        var statusFile = true
        init(_ running: [Bool]) { runningAnswers = running }
        func isRunning() -> Bool { runningAnswers.count > 1 ? runningAnswers.removeFirst() : runningAnswers[0] }
    }

    private func open(_ d: Dashboard, output: CLIOutput = Capture().output, failOpen: Bool = false) async -> Int32 {
        struct Refused: Error {}
        return await CLIRunner.openDashboard(
            output: output, isRunning: { d.isRunning() }, hasStatusFile: { d.statusFile },
            open: {
                d.opens += 1
                if failOpen { throw Refused() }
            }, sleep: { _ in d.sleeps += 1 })
    }

    @Test func aRunningAppGetsOneOpenAndNoWaitEvenWithoutAStatusFile() async {
        let d = Dashboard([true])
        d.statusFile = false  // an older app or an unwritable cache
        #expect(await open(d) == CLIExit.done)
        #expect(d.opens == 1 && d.sleeps == 0)
    }

    @Test func anAppThatStartsGetsASecondOpenWhenItRuns() async {
        let d = Dashboard([false, false, false, true])
        #expect(await open(d) == CLIExit.done)
        #expect(d.opens == 2)
    }

    @Test func anAppThatStartsWithoutAStatusFileStillGetsTheSecondOpen() async {
        let d = Dashboard([false, true])
        d.statusFile = false
        #expect(await open(d) == CLIExit.done)
        #expect(d.opens == 2)
    }

    @Test func anAppThatDoesNotStartIsAFailure() async {
        let d = Dashboard([false])
        let capture = Capture()
        #expect(await open(d, output: capture.output) == CLIExit.failed)
        #expect(capture.err == ["ColimaBar did not start in 10 seconds."])
        #expect(d.opens == 1)
    }

    @Test func aFailedOpenIsAFailure() async {
        let d = Dashboard([true])
        let capture = Capture()
        #expect(await open(d, output: capture.output, failOpen: true) == CLIExit.failed)
        #expect(capture.err.count == 1)
    }
}
