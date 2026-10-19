import Testing

@testable import ColimaBar

@Suite struct DNSHealthTests {
    @Test func theCommandLooksTheNameUpAndAlwaysExitsWithZero() {
        #expect(
            DNSHealth.vmCommand(profile: "work")
                == [
                    "colima", "ssh", "--profile", "work", "--", "bash", "-c",
                    "timeout 5 getent ahostsv4 registry-1.docker.io; echo \"colimabar-status=$?\"",
                ])
    }

    private func answer(_ code: Int, _ body: String = "") -> String { body + "colimabar-status=\(code)\n" }

    @Test func statusZeroWithAnAddressResolves() {
        let out = answer(0, "104.18.122.25   STREAM registry-1.docker.io\n104.18.122.25   DGRAM\n")
        #expect(DNSHealth.vmResult(status: 0, out: out) == .resolves)
    }

    @Test func statusZeroWithoutAnAddressIsUnknown() {
        #expect(DNSHealth.vmResult(status: 0, out: answer(0)) == .unknown)
        #expect(DNSHealth.vmResult(status: 0, out: answer(0, "no address here\n")) == .unknown)
        #expect(DNSHealth.vmResult(status: 0, out: answer(0, "999.1.1.1 STREAM\n")) == .unknown)
    }

    @Test func theStatusInTheMarkerHasOneMeaning() {
        #expect(DNSHealth.vmResult(status: 0, out: answer(2)) == .notFound)
        #expect(DNSHealth.vmResult(status: 0, out: answer(124)) == .timeout)
        #expect(DNSHealth.vmResult(status: 0, out: answer(1)) == .unknown)
        #expect(DNSHealth.vmResult(status: 0, out: answer(255)) == .unknown)
    }

    @Test func aFailedColimaSSHIsUnknownWhateverTheOutputSays() {
        #expect(DNSHealth.vmResult(status: 1, out: answer(2)) == .unknown)
        #expect(DNSHealth.vmResult(status: 255, out: answer(124)) == .unknown)
        #expect(DNSHealth.vmResult(status: -1, out: "") == .unknown)
    }

    @Test func anOutputWithoutAMarkerIsUnknown() {
        #expect(DNSHealth.vmResult(status: 0, out: "") == .unknown)
        #expect(DNSHealth.vmResult(status: 0, out: "104.18.122.25   STREAM registry-1.docker.io\n") == .unknown)
        #expect(DNSHealth.vmResult(status: 0, out: "colimabar-status=\n") == .unknown)
    }

    @Test func theLastMarkerWins() {
        #expect(DNSHealth.vmResult(status: 0, out: answer(124) + answer(2)) == .notFound)
    }

    @Test func theVerdictFollowsTheVMAndTheMac() {
        for mac in [true, false] {
            #expect(DNSHealth.verdict(vm: .resolves, mac: mac, override: false) == .ok)
            #expect(DNSHealth.verdict(vm: .unknown, mac: mac, override: false) == .unknown)
        }
        for vm in [DNSHealth.VMResult.notFound, .timeout] {
            #expect(DNSHealth.verdict(vm: vm, mac: true, override: false) == .broken(override: false))
            #expect(DNSHealth.verdict(vm: vm, mac: true, override: true) == .broken(override: true))
            #expect(DNSHealth.verdict(vm: vm, mac: false, override: true) == .macOffline)
        }
    }

    @Test func onlyABrokenReportIsBroken() {
        #expect(DNSHealth.Report(verdict: .broken(override: false)).isBroken)
        for v in [DNSHealth.Verdict.ok, .macOffline, .unknown] { #expect(!DNSHealth.Report(verdict: v).isBroken) }
    }

    @Test func theSplitDNSWarningNeedsAnOverrideAndDomains() {
        #expect(DNSHealth.splitDNSWarning(override: true, macSplitDomains: ["corp.example"]))
        #expect(!DNSHealth.splitDNSWarning(override: false, macSplitDomains: ["corp.example"]))
        #expect(!DNSHealth.splitDNSWarning(override: true, macSplitDomains: []))
    }

    @Test func theNotificationNamesTheProfileAndTheFix() {
        let plain = DNSHealth.notificationText(profile: "work", override: false)
        #expect(
            plain
                == "The VM of profile work cannot resolve host names after a network change. The Mac can. Click Restart to restart the VM."
        )
        let set = DNSHealth.notificationText(profile: "work", override: true)
        #expect(
            set
                == "The VM of profile work cannot resolve host names with the DNS servers in network.dns. The Mac can. Use the Mac's DNS in Doctor, or click Restart."
        )
    }

    @Test func theDomainListIsShort() {
        #expect(DNSHealth.domainList(["a.example", "b.example"]) == "a.example, b.example")
        #expect(DNSHealth.domainList(["a", "b", "c", "d", "e"]) == "a, b, c and 2 more")
    }

    @Test func theNoticeSaysIfNetworkDNSIsSet() {
        #expect(DNSHealth.noticeText(override: false) == "The VM cannot resolve host names. The Mac can.")
        #expect(
            DNSHealth.noticeText(override: true)
                == "The VM cannot resolve host names with the servers in network.dns. The Mac can.")
    }
}
