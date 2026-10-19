import Foundation

/// The rules of the DNS check: can the VM resolve a host name that the Mac
/// resolves? With an empty `network.dns`, the VM asks the Mac through the
/// Lima host agent, so it follows VPN and split DNS changes. A restart fixes
/// a VM that lost this. With `network.dns` set, the VM asks only those
/// servers.
enum DNSHealth {
    /// The name that both sides look up. A registry is what the VM needs most.
    static let host = "registry-1.docker.io"

    /// How long the lookup in the VM may take, in seconds.
    static let vmTimeout = 5

    enum VMResult: Equatable, Sendable {
        case resolves
        /// The resolver answered, and the name does not exist.
        case notFound
        case timeout
        /// `colima ssh` failed, or its output means nothing.
        case unknown
    }

    enum Verdict: Equatable, Sendable {
        case ok
        /// Neither the VM nor the Mac resolves the name: the network is down.
        case macOffline
        /// The VM cannot resolve the name and the Mac can. `override` is true
        /// if `network.dns` has servers.
        case broken(override: Bool)
        case unknown
    }

    struct Report: Equatable, Sendable {
        var verdict: Verdict

        var isBroken: Bool {
            if case .broken = verdict { return true }
            return false
        }
    }

    /// The text before the exit status of `getent` in the output of `vmCommand`.
    static let statusMarker = "colimabar-status="

    /// The command that looks the name up in the VM. `getent` uses the
    /// resolver of the guest, like any program in a container does.
    /// `colima ssh` exits with 1 for every failure of the remote command, so
    /// the remote shell always exits with 0 and prints the exit status of
    /// `getent` as a marker line.
    static func vmCommand(profile: String) -> [String] {
        let script = "timeout \(vmTimeout) getent ahostsv4 \(host); echo \"\(statusMarker)$?\""
        return ["colima", "ssh", "--profile", profile, "--", "bash", "-c", script]
    }

    /// `status` and `out` are the exit status and the output of `vmCommand`.
    /// A `colima ssh` that fails, or an output with no marker, is `unknown`.
    /// In the marker, `getent` exits with 2 if the name is not found, and
    /// `timeout` exits with 124.
    static func vmResult(status: Int32, out: String) -> VMResult {
        guard status == 0, let code = remoteStatus(out) else { return .unknown }
        switch code {
        case 0: return hasAddress(out) ? .resolves : .unknown
        case 2: return .notFound
        case 124: return .timeout
        default: return .unknown
        }
    }

    /// The number in the last marker line, or nil.
    private static func remoteStatus(_ out: String) -> Int? {
        out.split(whereSeparator: \.isNewline).last { $0.hasPrefix(statusMarker) }
            .flatMap { Int($0.dropFirst(statusMarker.count)) }
    }

    /// True if a line starts with an IPv4 address.
    private static func hasAddress(_ out: String) -> Bool {
        out.split(whereSeparator: \.isNewline).contains { line in
            guard let first = line.split(separator: " ").first else { return false }
            let parts = first.split(separator: ".", omittingEmptySubsequences: false)
            return parts.count == 4 && parts.allSatisfy { Int($0).map { (0...255).contains($0) } ?? false }
        }
    }

    static func verdict(vm: VMResult, mac: Bool, override: Bool) -> Verdict {
        switch vm {
        case .resolves: .ok
        case .unknown: .unknown
        case .notFound, .timeout: mac ? .broken(override: override) : .macOffline
        }
    }

    // MARK: Split DNS

    /// True if the Mac sends some domains to special DNS servers (a VPN does
    /// this) and the VM uses its own fixed servers, which do not know them.
    static func splitDNSWarning(override: Bool, macSplitDomains: [String]) -> Bool {
        override && !macSplitDomains.isEmpty
    }

    // MARK: Texts

    static func notificationText(profile: String, override: Bool) -> String {
        override
            ? "The VM of profile \(profile) cannot resolve host names with the DNS servers in network.dns. The Mac can. Use the Mac's DNS in Doctor, or click Restart."
            : "The VM of profile \(profile) cannot resolve host names after a network change. The Mac can. Click Restart to restart the VM."
    }

    /// The text of the notice in the dashboard.
    static func noticeText(override: Bool) -> String {
        override
            ? "The VM cannot resolve host names with the servers in network.dns. The Mac can."
            : "The VM cannot resolve host names. The Mac can."
    }

    /// "D1, D2", or "D1, D2, D3 and 2 more".
    static func domainList(_ domains: [String], shown: Int = 3) -> String {
        let head = domains.prefix(shown).joined(separator: ", ")
        return domains.count > shown ? "\(head) and \(domains.count - shown) more" : head
    }
}
