import CryptoKit
import Foundation

/// The DNS setup of the Mac, as the system reports it (`SCDynamicStore`).
/// The parse is pure. `NetworkObserver` reads the store.
struct MacDNSConfig: Equatable, Sendable {
    /// The DNS servers of the global setup, in order.
    var servers: [String] = []
    /// The domains that some service sends to its own servers (a VPN does
    /// this), sorted, with no duplicates.
    var splitDomains: [String] = []
    /// A short hash of everything above and the per-service servers. It is
    /// the same for the same setup, in any order of the input. It holds no
    /// address or name in clear text.
    var fingerprint = ""

    /// `global` is the value of `State:/Network/Global/DNS`. `services` are
    /// the values of `State:/Network/Service/ID/DNS`, by key.
    static func parse(global: [String: Any]?, services: [String: [String: Any]]) -> MacDNSConfig {
        let servers = strings(global?["ServerAddresses"])
        var domains = Set<String>()
        var lines: [String] = []
        for (key, value) in services {
            let own = strings(value["ServerAddresses"])
            let match = strings(value["SupplementalMatchDomains"]).filter(isSplitDomain)
            domains.formUnion(match)
            lines.append("\(key)|\(own.joined(separator: ","))|\(match.sorted().joined(separator: ","))")
        }
        let text = (["g|" + servers.joined(separator: ",")] + lines.sorted()).joined(separator: "\n")
        let hash = SHA256.hash(data: Data(text.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        return MacDNSConfig(servers: servers, splitDomains: domains.sorted(), fingerprint: hash)
    }

    private static func strings(_ value: Any?) -> [String] {
        (value as? [Any])?.compactMap { $0 as? String } ?? []
    }

    /// An empty match domain means all names, which is no split. A reverse
    /// zone or `local` is not one that a VPN adds for a company.
    private static func isSplitDomain(_ d: String) -> Bool {
        let lower = d.lowercased()
        return !lower.isEmpty && lower != "local" && !lower.hasSuffix(".arpa")
    }
}
