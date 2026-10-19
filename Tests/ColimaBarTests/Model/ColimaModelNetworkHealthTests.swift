import Foundation
import Testing

@testable import ColimaBar

@Suite struct ColimaModelNetworkHealthTests {
    private func row(_ name: String, running: Bool = true, runtime: String = "docker") -> ProfileRow {
        ProfileRow(
            name: name, isRunning: running, cpus: 2, memGB: 2, runtime: runtime, status: running ? "Running" : "Stopped"
        )
    }

    // MARK: settings

    @Test func aMissingFileGivesTheDefaults() {
        #expect(ColimaModel.networkSettings(yaml: nil) == ColimaModel.NetworkSettings())
        let s = ColimaModel.networkSettings(yaml: "cpu: 2\n")
        #expect(s.forwarder == "ssh" && !s.dnsOverride && !s.kubernetesWithAddress)
    }

    @Test func theForwarderAndTheDNSServersComeFromTheFile() {
        let s = ColimaModel.networkSettings(yaml: "portForwarder: grpc\nnetwork:\n  dns:\n    - 192.0.2.1\n")
        #expect(s.forwarder == "grpc" && s.dnsOverride)
        #expect(ColimaModel.networkSettings(yaml: "portForwarder: none\n").forwarder == "none")
    }

    @Test func kubernetesNeedsAnAddressToDropTheWebPorts() {
        let k8s = "kubernetes:\n  enabled: true\n"
        #expect(!ColimaModel.networkSettings(yaml: k8s).kubernetesWithAddress)
        #expect(ColimaModel.networkSettings(yaml: k8s + "network:\n  address: true\n").kubernetesWithAddress)
        #expect(!ColimaModel.networkSettings(yaml: "network:\n  address: true\n").kubernetesWithAddress)
    }

    // MARK: profiles

    @Test func onlyRunningProfilesWithValidNamesAreChecked() {
        let rows = [row("default"), row("work", running: false), row("bad name"), row("lab")]
        #expect(ColimaModel.networkProfiles(rows, blocked: []) == ["default", "lab"])
    }

    @Test func aBlockedProfileIsLeftOut() {
        let rows = [row("default"), row("lab")]
        #expect(ColimaModel.networkProfiles(rows, blocked: ["lab"]) == ["default"])
    }

    // MARK: notifications

    private let t0 = Date(timeIntervalSince1970: 1_000_000)
    private final class Clock: @unchecked Sendable {
        var now: Date
        init(_ d: Date) { now = d }
    }

    private func throttle(_ clock: Clock) -> AlertThrottle {
        AlertThrottle(window: 60 * 60, clock: { clock.now })
    }

    private func allowed(
        _ t: inout AlertThrottle, broken: Bool, inconclusive: Bool = false, notify: Bool = true, isDebug: Bool = false
    ) -> Bool {
        ColimaModel.networkAlertAllowed(
            broken: broken, inconclusive: inconclusive, key: "dns|work", notify: notify, isDebug: isDebug,
            throttle: &t)
    }

    @Test func aProblemThatStaysNotifiesOnceForEachWindow() {
        let clock = Clock(t0)
        var t = throttle(clock)
        #expect(allowed(&t, broken: true))
        clock.now = t0.addingTimeInterval(30 * 60)
        #expect(!allowed(&t, broken: true))
        clock.now = t0.addingTimeInterval(61 * 60)
        #expect(allowed(&t, broken: true))
    }

    @Test func aRecoveryLetsTheNextProblemNotifyAtOnce() {
        let clock = Clock(t0)
        var t = throttle(clock)
        #expect(allowed(&t, broken: true))
        #expect(!allowed(&t, broken: false))
        clock.now = t0.addingTimeInterval(60)
        #expect(allowed(&t, broken: true))
    }

    @Test func anInconclusiveResultKeepsTheState() {
        let clock = Clock(t0)
        var t = throttle(clock)
        #expect(allowed(&t, broken: true))
        #expect(!allowed(&t, broken: false, inconclusive: true))
        clock.now = t0.addingTimeInterval(60)
        #expect(!allowed(&t, broken: true))
    }

    @Test func aCheckOfTheDashboardOrADebugRunNeverNotifiesAndDoesNotUseTheWindow() {
        let clock = Clock(t0)
        var t = throttle(clock)
        #expect(!allowed(&t, broken: true, notify: false))
        #expect(!allowed(&t, broken: true, isDebug: true))
        #expect(allowed(&t, broken: true))
    }

    @Test func aFailedVMProbeOfThePortsIsInconclusive() {
        #expect(ColimaModel.portsInconclusive(PortHealth.Report(vmFailure: 1)))
        #expect(!ColimaModel.portsInconclusive(PortHealth.Report()))
    }

    @Test func portsWithNoAnswerFromTheVMAreUndecidedUnlessAPortIsBroken() {
        #expect(ColimaModel.portsUndecided(PortHealth.Report(unknown: [80])))
        #expect(!ColimaModel.portsUndecided(PortHealth.Report(broken: [80], unknown: [81])))
        #expect(!ColimaModel.portsUndecided(PortHealth.Report(okPorts: [80])))
    }

    @Test func onlyAnOkOrBrokenDNSVerdictIsConclusive() {
        #expect(ColimaModel.dnsInconclusive(.unknown) && ColimaModel.dnsInconclusive(.macOffline))
        #expect(!ColimaModel.dnsInconclusive(.ok) && !ColimaModel.dnsInconclusive(.broken(override: true)))
    }

    // MARK: when the dashboard opens

    @Test func anOpenDashboardChecksAfterFiveMinutes() {
        let now = Date(timeIntervalSince1970: 10_000)
        #expect(ColimaModel.needsOpenCheck(last: nil, now: now))
        #expect(!ColimaModel.needsOpenCheck(last: now.addingTimeInterval(-60), now: now))
        #expect(!ColimaModel.needsOpenCheck(last: now.addingTimeInterval(-300), now: now))
        #expect(ColimaModel.needsOpenCheck(last: now.addingTimeInterval(-301), now: now))
    }

    // MARK: Doctor probes of a stopped VM

    @Test func aStoppedVMIsNotProbed() async {
        let net = ColimaModel.NetworkSettings()
        #expect(
            await ColimaModel.doctorPorts(profile: "default", running: false, hasSocket: true, settings: net)
                == .vmStopped)
        #expect(await ColimaModel.doctorDNS(profile: "default", running: false, settings: net) == .vmStopped)
    }

    @Test func aRuntimeWithoutADockerSocketAndAForwarderOfNoneAreNotProbed() async {
        let net = ColimaModel.NetworkSettings()
        #expect(
            await ColimaModel.doctorPorts(profile: "default", running: true, hasSocket: false, settings: net)
                == .notDocker)
        var none = net
        none.forwarder = "none"
        #expect(
            await ColimaModel.doctorPorts(profile: "default", running: true, hasSocket: true, settings: none) == .off)
    }
}

@Suite struct NetworkPauseTests {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    @Test func noSleepMeansNoPause() {
        #expect(!ColimaModel.networkPauseActive(pausedAt: nil, now: t0))
    }

    @Test func aSleepPausesUntilTheLimit() {
        let limit = ColimaModel.networkPauseLimit
        #expect(ColimaModel.networkPauseActive(pausedAt: t0, now: t0.addingTimeInterval(limit - 1)))
        #expect(!ColimaModel.networkPauseActive(pausedAt: t0, now: t0.addingTimeInterval(limit)))
    }
}
