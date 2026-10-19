import Foundation
import Testing

@testable import ColimaBar

@Suite struct PortHealthTests {
    private struct Entry {
        var ip: String? = "0.0.0.0"
        var port: Int? = 8080
        var type = "tcp"
    }

    private func container(_ entries: [Entry], state: String = "running") throws -> APIContainer {
        let ports = entries.map { e -> String in
            var fields = ["\"PrivatePort\": 80", "\"Type\": \"\(e.type)\""]
            if let ip = e.ip { fields.append("\"IP\": \"\(ip)\"") }
            if let p = e.port { fields.append("\"PublicPort\": \(p)") }
            return "{" + fields.joined(separator: ",") + "}"
        }
        let json =
            "{\"Id\":\"a\",\"Names\":[\"/a\"],\"Image\":\"i\",\"State\":\"\(state)\",\"Status\":\"s\",\"Ports\":[\(ports.joined(separator: ","))]}"
        return try JSONDecoder().decode(APIContainer.self, from: Data(json.utf8))
    }

    private func targets(_ containers: [APIContainer], k8s: Bool = false) -> PortHealth.Targets {
        PortHealth.targets(containers: containers, kubernetesWithAddress: k8s)
    }

    // MARK: targets

    @Test func aRunningContainersTCPPortIsATarget() throws {
        #expect(targets([try container([Entry()])]).ports == [8080])
    }

    @Test func aStoppedContainerGivesNoTarget() throws {
        #expect(targets([try container([Entry()], state: "exited")]).ports.isEmpty)
    }

    @Test func aUDPPortIsNotATarget() throws {
        #expect(targets([try container([Entry(type: "udp")])]).ports.isEmpty)
    }

    @Test func anIPv4AndAnIPv6EntryGiveOneTarget() throws {
        let c = try container([Entry(ip: "0.0.0.0"), Entry(ip: "::")])
        #expect(targets([c]).ports == [8080])
    }

    @Test func loopbackAddressesAreTargets() throws {
        let c = try container([Entry(ip: "127.0.0.1", port: 1), Entry(ip: "::1", port: 2)])
        #expect(targets([c]).ports == [1, 2])
    }

    @Test func anotherHostAddressIsCountedAndNotProbed() throws {
        let c = try container([Entry(ip: "192.0.2.5", port: 9000), Entry(ip: "192.0.2.5", port: 9001)])
        let t = targets([c])
        #expect(t.ports.isEmpty && t.skippedOtherIP == 2)
    }

    @Test func aPortWithoutAHostPortOrAddressIsIgnored() throws {
        let c = try container([Entry(port: nil), Entry(ip: nil), Entry(port: 0), Entry(port: 70000)])
        let t = targets([c])
        #expect(t.ports.isEmpty && t.skippedOtherIP == 0)
    }

    @Test func kubernetesWithAnAddressDropsTheWebPorts() throws {
        let c = try container([Entry(port: 80), Entry(port: 443), Entry(port: 8080)])
        #expect(targets([c], k8s: true).ports == [8080])
        #expect(targets([c], k8s: false).ports == [80, 443, 8080])
    }

    @Test func targetsAreSortedWithNoDuplicatesAcrossContainers() throws {
        let a = try container([Entry(port: 9000), Entry(port: 80)])
        let b = try container([Entry(port: 80), Entry(port: 5432)])
        #expect(targets([a, b]).ports == [80, 5432, 9000])
    }

    @Test func atMostThirtyTwoPortsAreTargets() throws {
        let c = try container((1...50).map { Entry(port: 20000 + $0) })
        let t = targets([c])
        #expect(t.ports.count == PortHealth.cap)
        #expect(t.ports.first == 20001)
    }

    @Test func aContainerWithoutPortsGivesNoTarget() throws {
        let json = #"{"Id":"a","Names":["/a"],"Image":"i","State":"running","Status":"s"}"#
        let c = try JSONDecoder().decode(APIContainer.self, from: Data(json.utf8))
        #expect(targets([c]).ports.isEmpty)
    }

    // MARK: VM script

    @Test func theScriptHoldsOnlyTheIntegersOfValidPorts() {
        let script = PortHealth.vmScript(ports: [8080, 0, -5, 70000, 5432])
        #expect(script.contains("\"8080 $r\"") && script.contains("\"5432 $r\""))
        #expect(!script.contains("70000") && !script.contains("-5") && !script.contains("\"0 $r\""))
    }

    @Test func theScriptStartsEachProbeInTheBackgroundAndWaits() {
        let lines = PortHealth.vmScript(ports: [8080, 5432, 9000]).split(separator: "\n").map(String.init)
        #expect(lines.count == 4)
        #expect(lines.dropLast().allSatisfy { $0.hasPrefix("( ") && $0.hasSuffix(" ) &") })
        #expect(lines.last == "wait")
    }

    @Test func eachProbePrintsOneWholeLineWithOneWrite() {
        let script = PortHealth.vmScript(ports: [8080])
        #expect(script.contains("printf '%s\\n' \"8080 $r\""))
        #expect(!script.contains("echo"))
    }

    @Test func aScriptWithoutPortsIsEmpty() {
        #expect(PortHealth.vmScript(ports: [0, 70000]).isEmpty)
    }

    @Test func theScriptHasNoCharacterFromAContainer() {
        let script = PortHealth.vmScript(ports: [8080])
        #expect(!script.contains(";;;") && !script.contains("`") && !script.contains("&&&"))
        #expect(script.contains("/dev/tcp/127.0.0.1/$0"))
        #expect(PortHealth.vmScript(ports: []).isEmpty)
    }

    // MARK: parseVM

    @Test func parseVMReadsThreeAnswers() {
        let out = "8080 open\n5432 closed\n9000 refused\n"
        #expect(PortHealth.parseVM(out) == [8080: .open, 5432: .closed, 9000: .refused])
    }

    @Test func parseVMDropsLinesThatDoNotFit() {
        let out = "8080 open\nwarning: something\n9000\n9001 maybe\nabc open\n70000 open\n1 2 3\n\n 22 closed"
        #expect(PortHealth.parseVM(out) == [8080: .open, 22: .closed])
    }

    // MARK: verdict

    @Test func theVerdictOfEveryCell() {
        let hosts: [PortProbe.Result] = [.open, .closed, .refused, .timeout]
        for host in hosts {
            let open = host == .open
            #expect(PortHealth.verdict(host: host, vm: .open) == (open ? .ok : .broken))
            #expect(PortHealth.verdict(host: host, vm: .closed) == (open ? .ok : .notListening))
            #expect(PortHealth.verdict(host: host, vm: .refused) == (open ? .ok : .notListening))
            #expect(PortHealth.verdict(host: host, vm: nil) == (open ? .ok : .unknown))
        }
    }

    @Test func aReportSortsEachPortByItsVerdict() {
        let t = PortHealth.Targets(ports: [1, 2, 3, 4], skippedOtherIP: 2)
        let host: [Int: PortProbe.Result] = [1: .open, 2: .refused, 3: .closed, 4: .timeout]
        let r = PortHealth.report(targets: t, host: host, vm: [2: .open, 3: .refused])
        #expect(r.okPorts == [1] && r.broken == [2] && r.notListening == [3] && r.unknown == [4])
        #expect(r.skippedOtherIP == 2 && r.total == 4 && r.isBroken)
    }

    @Test func aFailedVMProbeLeavesTheClosedPortsUnknown() {
        let t = PortHealth.Targets(ports: [1, 2])
        let r = PortHealth.report(targets: t, host: [1: .open, 2: .refused], vm: nil, vmFailure: 255)
        #expect(r.okPorts == [1] && r.unknown == [2] && r.vmFailure == 255 && !r.isBroken)
    }

    @Test func aLocalProbeFailureIsNeverBroken() {
        for vm in [PortHealth.VMResult.open, .closed, .refused] {
            #expect(PortHealth.verdict(host: .error, vm: vm) == .unknown)
        }
        #expect(PortHealth.verdict(host: .error, vm: nil) == .unknown)
    }

    // MARK: confirm

    @Test func aBrokenPortWithALocalProbeFailureBecomesUnknown() {
        var r = PortHealth.Report()
        r.broken = [8080, 9000]
        let c = PortHealth.confirmed(r, host: [8080: .error, 9000: .closed])
        #expect(c.broken == [9000] && c.unknown == [8080])
    }

    @Test func aBrokenPortThatAnswersAgainMovesToOk() {
        var r = PortHealth.Report()
        r.okPorts = [80]
        r.broken = [8080, 9000]
        let c = PortHealth.confirmed(r, host: [8080: .open, 9000: .closed])
        #expect(c.broken == [9000] && c.okPorts == [80, 8080])
    }

    @Test func aBrokenPortWithNoSecondResultStaysBroken() {
        var r = PortHealth.Report()
        r.broken = [8080]
        #expect(PortHealth.confirmed(r, host: [:]).broken == [8080])
    }

    // MARK: texts

    @Test func thePortListIsShort() {
        #expect(PortHealth.list([8080, 5432]) == "8080, 5432")
        #expect(PortHealth.list([1, 2, 3, 4, 5, 6, 7]) == "1, 2, 3, 4, 5 and 2 more")
    }

    @Test func theNotificationNamesTheProfileAndThePorts() {
        let text = PortHealth.notificationText(profile: "work", ports: [8080, 5432], forwarder: "ssh")
        #expect(
            text
                == "Published ports of profile work do not answer on the Mac: 8080, 5432. They answer in the VM, so port forwarding is broken. Click Restart to restart the VM."
        )
    }

    @Test func theNotificationAdvisesSSHOnlyForGRPC() {
        let grpc = PortHealth.notificationText(profile: "work", ports: [1], forwarder: "grpc")
        #expect(grpc.hasSuffix(" The ssh port forwarder is more stable. See Doctor."))
        #expect(!PortHealth.notificationText(profile: "work", ports: [1], forwarder: "ssh").contains("stable"))
    }

    @Test func theSkippedNoteCountsThePorts() {
        #expect(PortHealth.skippedNote(1) == "1 port bound to another host address is not checked.")
        #expect(PortHealth.skippedNote(3) == "3 ports bound to other host addresses are not checked.")
    }

    @Test func theNoticeNamesTheBrokenPorts() {
        #expect(PortHealth.noticeText(ports: [8080]).hasPrefix("Ports 8080 answer in the VM but not on the Mac."))
    }
}
