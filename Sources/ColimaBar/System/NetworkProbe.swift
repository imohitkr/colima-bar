import Foundation
import os

/// The I/O of the network checks: the ports of the containers and the DNS
/// of the VM. Each call only reads. None of them starts the VM: the caller
/// calls them only while the VM runs, and the VM calls go through
/// `colima ssh` on the profile, never through a proxy socket.
enum NetworkProbe {
    private static let log = Logger(category: "network")

    /// Compares the published ports on the Mac with the ports in the VM.
    /// The container list comes from the Colima socket of the profile.
    static func ports(profile: String, kubernetesWithAddress: Bool) async -> PortHealth.Probe {
        let api = DockerAPI(socketPath: Paths.socket(profile))
        guard let reply = await api.get("/containers/json", timeout: 5), reply.ok,
            let list = try? JSONDecoder().decode([APIContainer].self, from: reply.body)
        else { return .noContainerList }
        let targets = PortHealth.targets(containers: list, kubernetesWithAddress: kubernetesWithAddress)
        let host = await PortProbe.check(ports: targets.ports)
        // Only a port that does not answer on the Mac needs a look in the VM.
        let suspect = targets.ports.filter { host[$0] != .open }
        var vm: [Int: PortHealth.VMResult]?
        var failure: Int32?
        if !suspect.isEmpty {
            let r = await Shell.run(
                ["colima", "ssh", "--profile", profile, "--", "bash", "-c", PortHealth.vmScript(ports: suspect)],
                timeout: 15, cancellable: true)
            if r.ok { vm = PortHealth.parseVM(r.out) } else { failure = r.status }
        }
        return .checked(PortHealth.report(targets: targets, host: host, vm: vm, vmFailure: failure))
    }

    /// Looks up `DNSHealth.host` in the VM and on the Mac at the same time.
    static func dns(profile: String, override: Bool) async -> DNSHealth.Report {
        async let vm = Shell.run(DNSHealth.vmCommand(profile: profile), timeout: 15, cancellable: true)
        async let mac = HostLookup.resolves(DNSHealth.host)
        let result = await vm
        let vmResult = DNSHealth.vmResult(status: result.status, out: result.out)
        if vmResult == .unknown {
            log.error(
                "DNS look-up in profile \(profile, privacy: .public): colima ssh exit \(result.status, privacy: .public)"
            )
        }
        return DNSHealth.Report(verdict: DNSHealth.verdict(vm: vmResult, mac: await mac, override: override))
    }
}
