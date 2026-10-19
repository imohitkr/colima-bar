import Foundation

/// The rules of the checks "Port forwarding" and "DNS in the VM".
extension DoctorRules {
    static func portForwarding(_ i: DoctorInputs) -> DoctorResult {
        func skipped(_ text: String) -> DoctorResult { DoctorResult(.portForwarding, .skipped, text) }
        let report: PortHealth.Report
        switch i.ports {
        case .vmStopped: return skipped("The VM is stopped, so ColimaBar did not check the ports.")
        case .notDocker: return skipped("Only the docker runtime has published ports to check.")
        case .off: return skipped("Port forwarding is off (portForwarder: none).")
        case .noContainerList: return skipped("Docker did not answer, so ColimaBar did not check the ports.")
        case .checked(let r): report = r
        }
        let note = report.skippedOtherIP > 0 ? " " + PortHealth.skippedNote(report.skippedOtherIP) : ""
        if report.isBroken {
            let grpc = i.portForwarder == "grpc"
            let text =
                "Ports \(PortHealth.list(report.broken)) answer in the VM but not on the Mac. Restart the VM."
                + (grpc ? " The grpc port forwarder is experimental. Use the ssh port forwarder." : "")
            return DoctorResult(
                .portForwarding, .problem, text + note, fix: grpc ? .useSSHForwarder : .restartVM)
        }
        if !report.unknown.isEmpty {
            let text =
                report.vmFailure.map { "colima ssh failed (exit \($0)), so ColimaBar could not compare the ports." }
                ?? "The VM gave no answer for some ports, so ColimaBar could not compare them."
            return skipped(text + note)
        }
        if !report.notListening.isEmpty {
            return DoctorResult(
                .portForwarding, .warning,
                "Ports \(PortHealth.list(report.notListening)) do not answer on the Mac or in the VM. Check the app in the container."
                    + note)
        }
        if report.total == 0 { return DoctorResult(.portForwarding, .ok, "No published TCP ports to check." + note) }
        let n = report.total
        return DoctorResult(
            .portForwarding, .ok, "\(n) published \(n == 1 ? "port answers" : "ports answer") on the Mac." + note)
    }

    static func vmDNS(_ i: DoctorInputs) -> DoctorResult {
        let host = DNSHealth.host
        guard case .checked(let report) = i.dns else {
            return DoctorResult(.vmDNS, .skipped, "The VM is stopped, so ColimaBar did not check DNS.")
        }
        switch report.verdict {
        case .ok:
            if DNSHealth.splitDNSWarning(override: i.dnsOverride, macSplitDomains: i.macSplitDomains) {
                return DoctorResult(
                    .vmDNS, .warning,
                    "The VPN sends some domains (\(DNSHealth.domainList(i.macSplitDomains))) to its own DNS servers. The servers in network.dns do not know them. Use the Mac's DNS.",
                    fix: .useMacDNS,
                    shareDetail:
                        "The VPN uses split DNS for some domains. The servers in network.dns do not know them. Use the Mac's DNS."
                )
            }
            return DoctorResult(.vmDNS, .ok, "The VM resolves \(host).")
        case .macOffline:
            return DoctorResult(
                .vmDNS, .skipped, "The Mac cannot resolve \(host) either. Check the network of the Mac.")
        case .broken(let override):
            return override
                ? DoctorResult(
                    .vmDNS, .problem,
                    "The VM cannot resolve \(host) with the servers in network.dns. The Mac can. Use the Mac's DNS.",
                    fix: .useMacDNS)
                : DoctorResult(
                    .vmDNS, .problem, "The VM cannot resolve \(host). The Mac can. Restart the VM.", fix: .restartVM)
        case .unknown:
            return DoctorResult(.vmDNS, .skipped, "colima ssh did not answer, so ColimaBar could not check DNS.")
        }
    }
}
