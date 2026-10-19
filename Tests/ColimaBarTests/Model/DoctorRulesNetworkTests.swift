import Foundation
import Testing

@testable import ColimaBar

@Suite struct DoctorRulesNetworkTests {
    private func ports(_ probe: PortHealth.Probe, forwarder: String = "ssh") -> DoctorResult {
        var i = DoctorFixture.healthy()
        i.ports = probe
        i.portForwarder = forwarder
        return DoctorRules.portForwarding(i)
    }

    private func dns(
        _ verdict: DNSHealth.Verdict, override: Bool = false, split: [String] = []
    ) -> DoctorResult {
        var i = DoctorFixture.healthy()
        i.dns = .checked(DNSHealth.Report(verdict: verdict))
        i.dnsOverride = override
        i.macSplitDomains = split
        return DoctorRules.vmDNS(i)
    }

    private func report(
        ok: [Int] = [], broken: [Int] = [], silent: [Int] = [], unknown: [Int] = [], other: Int = 0,
        failure: Int32? = nil
    ) -> PortHealth.Probe {
        .checked(
            PortHealth.Report(
                okPorts: ok, broken: broken, notListening: silent, unknown: unknown, skippedOtherIP: other,
                vmFailure: failure))
    }

    @Test func theNewChecksComeAfterDiskSpace() {
        let ids = DoctorRules.evaluate(DoctorFixture.healthy()).map(\.check)
        #expect(Array(ids.suffix(3)) == [.diskSpace, .portForwarding, .vmDNS])
        #expect(DoctorCheck.portForwarding.title == "Port forwarding" && DoctorCheck.vmDNS.title == "DNS in the VM")
    }

    // MARK: port forwarding

    @Test func portsThatAnswerAreOk() {
        let r = ports(report(ok: [80, 8080]))
        #expect(r.status == .ok && r.fix == nil && r.detail == "2 published ports answer on the Mac.")
        #expect(ports(report(ok: [80])).detail == "1 published port answers on the Mac.")
    }

    @Test func noPublishedPortsIsOk() {
        let r = ports(report())
        #expect(r.status == .ok && r.detail == "No published TCP ports to check.")
    }

    @Test func aBrokenPortIsAProblemWithRestart() {
        let r = ports(report(ok: [80], broken: [8080, 5432]))
        #expect(r.status == .problem && r.fix == .restartVM)
        #expect(r.detail == "Ports 8080, 5432 answer in the VM but not on the Mac. Restart the VM.")
    }

    @Test func aBrokenPortWithGRPCOffersTheSSHForwarder() {
        let r = ports(report(broken: [8080]), forwarder: "grpc")
        #expect(r.status == .problem && r.fix == .useSSHForwarder)
        #expect(r.detail.hasSuffix("The grpc port forwarder is experimental. Use the ssh port forwarder."))
    }

    @Test func aPortThatAnswersNowhereIsAWarningWithNoFix() {
        let r = ports(report(ok: [80], silent: [9000]))
        #expect(r.status == .warning && r.fix == nil)
        #expect(r.detail == "Ports 9000 do not answer on the Mac or in the VM. Check the app in the container.")
    }

    @Test func aBrokenPortOutranksASilentPort() {
        #expect(ports(report(broken: [1], silent: [2])).status == .problem)
    }

    @Test func aFailedVMProbeIsSkippedWithTheExitStatus() {
        let r = ports(report(unknown: [8080], failure: 255))
        #expect(r.status == .skipped && r.fix == nil)
        #expect(r.detail == "colima ssh failed (exit 255), so ColimaBar could not compare the ports.")
        #expect(ports(report(unknown: [8080])).status == .skipped)
    }

    @Test func portsBoundToOtherAddressesAddANote() {
        #expect(
            ports(report(ok: [80], other: 2)).detail.hasSuffix(
                " 2 ports bound to other host addresses are not checked."))
        #expect(ports(report(other: 1)).detail.contains("1 port bound to another host address is not checked."))
        #expect(ports(report(broken: [1], other: 1)).detail.contains("not checked."))
    }

    @Test func thePortsAreSkippedWhenThereIsNoProbe() {
        #expect(ports(.vmStopped).detail == "The VM is stopped, so ColimaBar did not check the ports.")
        #expect(ports(.notDocker).detail == "Only the docker runtime has published ports to check.")
        #expect(ports(.off).detail == "Port forwarding is off (portForwarder: none).")
        #expect(ports(.noContainerList).detail == "Docker did not answer, so ColimaBar did not check the ports.")
        for p in [PortHealth.Probe.vmStopped, .notDocker, .off, .noContainerList] {
            let r = ports(p)
            #expect(r.status == .skipped && r.fix == nil)
        }
    }

    // MARK: DNS

    @Test func aVMThatResolvesIsOk() {
        let r = dns(.ok)
        #expect(r.status == .ok && r.fix == nil && r.detail == "The VM resolves registry-1.docker.io.")
    }

    @Test func aBrokenVMWithoutOverrideIsAProblemWithRestart() {
        let r = dns(.broken(override: false))
        #expect(r.status == .problem && r.fix == .restartVM)
        #expect(r.detail == "The VM cannot resolve registry-1.docker.io. The Mac can. Restart the VM.")
    }

    @Test func aBrokenVMWithOverrideIsAProblemWithTheMacDNS() {
        let r = dns(.broken(override: true), override: true)
        #expect(r.status == .problem && r.fix == .useMacDNS)
        #expect(
            r.detail
                == "The VM cannot resolve registry-1.docker.io with the servers in network.dns. The Mac can. Use the Mac's DNS."
        )
    }

    @Test func aMacThatIsOfflineIsSkipped() {
        let r = dns(.macOffline)
        #expect(r.status == .skipped && r.fix == nil)
        #expect(r.detail == "The Mac cannot resolve registry-1.docker.io either. Check the network of the Mac.")
    }

    @Test func anUnknownResultIsSkipped() {
        #expect(dns(.unknown).status == .skipped)
    }

    @Test func aStoppedVMIsSkipped() {
        var i = DoctorFixture.healthy()
        i.dns = .vmStopped
        let r = DoctorRules.vmDNS(i)
        #expect(r.status == .skipped && r.detail == "The VM is stopped, so ColimaBar did not check DNS.")
    }

    @Test func aVPNWithSplitDNSAndAnOverrideIsAWarningWithTheMacDNS() {
        let r = dns(.ok, override: true, split: ["corp.example", "lab.example"])
        #expect(r.status == .warning && r.fix == .useMacDNS)
        #expect(r.detail.contains("(corp.example, lab.example)"))
    }

    @Test func theSplitDNSWarningNeedsAnOverride() {
        #expect(dns(.ok, override: false, split: ["corp.example"]).status == .ok)
        #expect(dns(.ok, override: true, split: []).status == .ok)
    }

    @Test func theSharedSplitDNSTextHasNoDomain() {
        let r = dns(.ok, override: true, split: ["corp.example"])
        #expect(
            r.sharedDetail
                == "The VPN uses split DNS for some domains. The servers in network.dns do not know them. Use the Mac's DNS."
        )
        #expect(!r.sharedDetail.contains("corp.example"))
    }

    @Test func noSharedTextHoldsAnAddress() {
        let all = [
            dns(.ok), dns(.broken(override: true)), dns(.macOffline), dns(.ok, override: true, split: ["a.example"]),
            ports(report(ok: [80], broken: [8080], other: 1)),
        ]
        for r in all {
            let text = r.sharedDetail
            #expect(text.range(of: #"\d+\.\d+\.\d+\.\d+"#, options: .regularExpression) == nil)
        }
    }

    // MARK: fixes

    @Test func theNewFixesHaveFixedNamesAndLabels() {
        #expect(DoctorFix.restartVM.id == "restartVM" && DoctorFix.restartVM.label == "Restart")
        #expect(DoctorFix.useSSHForwarder.id == "useSSHForwarder")
        #expect(DoctorFix.useSSHForwarder.label == "Use ssh forwarder")
        #expect(DoctorFix.useMacDNS.id == "useMacDNS" && DoctorFix.useMacDNS.label == "Use the Mac's DNS")
    }
}
