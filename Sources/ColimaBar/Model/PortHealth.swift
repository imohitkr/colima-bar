import Foundation

/// The rules of the port forwarding check: which published ports to probe,
/// the script for the VM, and what the results mean. No I/O.
///
/// A published port must answer on the Mac (127.0.0.1). If it does not
/// answer on the Mac but answers in the VM, the forward is broken.
enum PortHealth {
    /// The most ports that one check probes.
    static let cap = 32

    /// What the VM says about a port.
    enum VMResult: Equatable, Sendable { case open, closed, refused }

    enum Verdict: Equatable, Sendable {
        /// The port answers on the Mac.
        case ok
        /// The port answers in the VM but not on the Mac.
        case broken
        /// The port answers nowhere. The app in the container may be down.
        case notListening
        /// The VM gave no result.
        case unknown
    }

    /// The ports to probe, and how many ColimaBar left out.
    struct Targets: Equatable, Sendable {
        var ports: [Int] = []
        /// Ports bound to an address other than the Mac itself.
        var skippedOtherIP = 0
    }

    /// The result of one check of one profile. It has no date: the model
    /// stores a new value only when the report changes.
    struct Report: Equatable, Sendable {
        var okPorts: [Int] = []
        var broken: [Int] = []
        var notListening: [Int] = []
        var unknown: [Int] = []
        var skippedOtherIP = 0
        /// The exit status of `colima ssh`, if the VM probe failed.
        var vmFailure: Int32?

        /// Ports that were probed.
        var total: Int { okPorts.count + broken.count + notListening.count + unknown.count }
        var isBroken: Bool { !broken.isEmpty }
    }

    /// What a check of one profile gave.
    enum Probe: Equatable, Sendable {
        /// The VM is stopped, so ColimaBar did not probe.
        case vmStopped
        /// The runtime has no docker socket.
        case notDocker
        /// `portForwarder: none`: Colima forwards no port.
        case off
        /// The container list did not come from docker.
        case noContainerList
        case checked(Report)
    }

    // MARK: Targets

    private static let hostAddresses: Set<String> = ["0.0.0.0", "::", "127.0.0.1", "::1"]

    /// The published TCP ports of the running containers, sorted, with no
    /// duplicates (docker lists one entry for IPv4 and one for IPv6), at most
    /// `cap`. Colima ignores the ports 80 and 443 when Kubernetes and
    /// `network.address` are both on, so they are not probed then.
    static func targets(containers: [APIContainer], kubernetesWithAddress: Bool) -> Targets {
        var ports = Set<Int>()
        var other = Set<String>()
        for c in containers where c.State == "running" {
            for p in c.Ports ?? [] {
                guard p.Type == "tcp", let port = p.PublicPort, (1...65535).contains(port) else { continue }
                guard let ip = p.IP, !ip.isEmpty else { continue }
                guard hostAddresses.contains(ip) else {
                    other.insert("\(ip)|\(port)")
                    continue
                }
                if kubernetesWithAddress, port == 80 || port == 443 { continue }
                ports.insert(port)
            }
        }
        return Targets(ports: Array(ports.sorted().prefix(cap)), skippedOtherIP: other.count)
    }

    // MARK: VM probe

    /// The script for `colima ssh -- bash -c SCRIPT`. It holds integers only,
    /// so no text of a container can reach a shell. For each port it prints
    /// one line `PORT open|closed|refused`. A port that accepts and closes at
    /// once is `closed`. A port that accepts and stays quiet is `open`.
    /// Each probe runs in the background and `wait` ends the script, so the
    /// time of the script does not grow with the number of quiet ports.
    static func vmScript(ports: [Int]) -> String {
        let valid = ports.filter { (1...65535).contains($0) }
        guard !valid.isEmpty else { return "" }
        let probe = "exec 3<>/dev/tcp/127.0.0.1/$0; read -r -t 0.5 -n 1 <&3; [ $? -eq 1 ] && exit 3; exit 0"
        let lines = valid.map { p in
            "( timeout 2 bash -c '\(probe)' \(p) 2>/dev/null; "
                + "case $? in 0) r=open;; 3) r=closed;; *) r=refused;; esac; printf '%s\\n' \"\(p) $r\" ) &"
        }
        return (lines + ["wait"]).joined(separator: "\n")
    }

    /// Reads the lines of `vmScript`. A line that does not fit is dropped.
    static func parseVM(_ output: String) -> [Int: VMResult] {
        var out: [Int: VMResult] = [:]
        for line in output.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: " ")
            guard parts.count == 2, let port = Int(parts[0]), (1...65535).contains(port) else { continue }
            switch parts[1] {
            case "open": out[port] = .open
            case "closed": out[port] = .closed
            case "refused": out[port] = .refused
            default: continue
            }
        }
        return out
    }

    // MARK: Verdict

    /// `vm` is nil when ColimaBar did not get a result from the VM.
    static func verdict(host: PortProbe.Result, vm: VMResult?) -> Verdict {
        if host == .open { return .ok }
        // A local failure of the probe says nothing about the port.
        if host == .error { return .unknown }
        switch vm {
        case .open?: return .broken
        case .closed?, .refused?: return .notListening
        case nil: return .unknown
        }
    }

    /// Joins the probes of all ports into one report.
    static func report(
        targets: Targets, host: [Int: PortProbe.Result], vm: [Int: VMResult]?, vmFailure: Int32? = nil
    ) -> Report {
        var r = Report(skippedOtherIP: targets.skippedOtherIP, vmFailure: vmFailure)
        for port in targets.ports {
            guard let h = host[port] else { continue }
            switch verdict(host: h, vm: vm?[port]) {
            case .ok: r.okPorts.append(port)
            case .broken: r.broken.append(port)
            case .notListening: r.notListening.append(port)
            case .unknown: r.unknown.append(port)
            }
        }
        return r
    }

    /// Keeps a port as broken only if the Mac probe fails again. A port that
    /// answers now moves to the ok list. `host` has the second probe of the
    /// ports that were broken. A port with a local probe failure becomes unknown.
    static func confirmed(_ report: Report, host: [Int: PortProbe.Result]) -> Report {
        var r = report
        let healed = report.broken.filter { host[$0] == .open }
        let failed = report.broken.filter { host[$0] == .error }
        r.broken = report.broken.filter { host[$0] != .open && host[$0] != .error }
        r.okPorts = (report.okPorts + healed).sorted()
        r.unknown = (report.unknown + failed).sorted()
        return r
    }

    // MARK: Texts

    /// "8080, 5432", or "8080, 5432, 9000, 9001, 9002 and 4 more".
    static func list(_ ports: [Int], shown: Int = 5) -> String {
        let head = ports.prefix(shown).map(String.init).joined(separator: ", ")
        guard ports.count > shown else { return head }
        return "\(head) and \(ports.count - shown) more"
    }

    static func notificationText(profile: String, ports: [Int], forwarder: String) -> String {
        var text =
            "Published ports of profile \(profile) do not answer on the Mac: \(list(ports)). They answer in the VM, so port forwarding is broken. Click Restart to restart the VM."
        if forwarder == "grpc" { text += " The ssh port forwarder is more stable. See Doctor." }
        return text
    }

    /// The text of the notice in the dashboard.
    static func noticeText(ports: [Int]) -> String {
        "Ports \(list(ports)) answer in the VM but not on the Mac. Port forwarding is broken."
    }

    static func skippedNote(_ count: Int) -> String {
        count == 1
            ? "1 port bound to another host address is not checked."
            : "\(count) ports bound to other host addresses are not checked."
    }
}
