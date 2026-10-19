import Foundation

/// Checks a `VMSettingsChange` before ColimaBar writes it. The checks use no
/// file or network, except the folder test in `Context`, so a test can give
/// its own.
enum VMSettingsCheck {
    /// What the checks need to know besides the change.
    struct Context {
        /// colima.yaml now: the VM type, the runtime and the address.
        var current = VMSettings.Read()
        var home = Paths.home
        /// True if the path is a folder that exists.
        var isFolder: (String) -> Bool = { path in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
        }
    }

    static let maxDNSServers = 3

    /// The reasons that ColimaBar must not write the change, one sentence each.
    static func problems(_ change: VMSettingsChange, context: Context) -> [String] {
        var out: [String] = []
        if let dns = change.dnsServers { out += dnsProblems(dns) }
        if let forwarder = change.portForwarder, !["ssh", "grpc", "none"].contains(forwarder) {
            out.append("The port forwarder must be ssh, grpc or none.")
        }
        if change.address == true, !context.current.usesVZ {
            out.append("A reachable IP address needs the vz VM type.")
        }
        if change.address == false, context.current.address {
            out.append("Colima cannot turn off the address of this VM.")
        }
        if let mounts = change.mounts { out += mountProblems(mounts, context: context) }
        if let mirrors = change.registryMirrors { out += mirrorProblems(mirrors) }
        if let insecure = change.insecureRegistries { out += insecureProblems(insecure) }
        let registries = (change.registryMirrors ?? []) + (change.insecureRegistries ?? [])
        if !registries.isEmpty, !context.current.usesDocker {
            out.append("Registries need the docker runtime.")
        }
        return out
    }

    // MARK: DNS

    static func isIPAddress(_ s: String) -> Bool {
        var v4 = in_addr()
        var v6 = in6_addr()
        return inet_pton(AF_INET, s, &v4) == 1 || inet_pton(AF_INET6, s, &v6) == 1
    }

    private static func dnsProblems(_ servers: [String]) -> [String] {
        var out: [String] = []
        for s in servers where !isIPAddress(s) { out.append("\(s) is not an IP address.") }
        out += duplicates(servers).map { "\($0) is in the DNS list twice." }
        if servers.count > maxDNSServers { out.append("Use at most \(maxDNSServers) DNS servers.") }
        return out
    }

    // MARK: Mounts

    /// The absolute path of a mount location, or nil if it does not start
    /// with `/`, `~/` or is `~`.
    static func expanded(_ location: String, home: String) -> String? {
        let path: String
        if location == "~" {
            path = home
        } else if location.hasPrefix("~/") {
            path = home + String(location.dropFirst())
        } else if location.hasPrefix("/") {
            path = location
        } else {
            return nil
        }
        let clean = (path as NSString).standardizingPath
        return clean.isEmpty ? nil : clean
    }

    /// Colima 0.10.3 refuses a list where the text of one path (the mount
    /// point, or else the folder) starts with the text of another
    /// (`checkOverlappingMounts`). The same path twice has its own message.
    private static func overlaps(_ mounts: [VMMount], context: Context) -> [String] {
        let paths = mounts.map { m -> (label: String, path: String)? in
            let text = m.mountPoint.flatMap { $0.isEmpty ? nil : $0 } ?? m.location
            return expanded(text, home: context.home).map { (text, $0) }
        }
        var out: [String] = []
        for i in paths.indices {
            for j in paths.indices where j > i {
                guard let a = paths[i], let b = paths[j], a.path != b.path else { continue }
                if a.path.hasPrefix(b.path) || b.path.hasPrefix(a.path) {
                    out.append("\(a.label) and \(b.label) overlap. Colima does not start with overlapping folders.")
                }
            }
        }
        return out
    }

    private static func mountProblems(_ mounts: [VMMount], context: Context) -> [String] {
        var out: [String] = []
        var seen: [String] = []
        for m in mounts {
            if (m.location + (m.mountPoint ?? "")).unicodeScalars.contains(where: {
                $0.properties.generalCategory == .control
            }) {
                out.append("Folder names with line breaks or control characters are not supported.")
                continue
            }
            guard let path = expanded(m.location, home: context.home) else {
                out.append("\(m.location) must start with / or ~/.")
                continue
            }
            if path == "/" {
                out.append("Do not mount the root folder /.")
            } else if !context.isFolder(path) {
                out.append("\(m.location) is not a folder on this Mac.")
            }
            if seen.contains(path) { out.append("\(m.location) is in the list twice.") }
            seen.append(path)
        }
        out += overlaps(mounts, context: context)
        return out
    }

    // MARK: Registries

    private static func mirrorProblems(_ mirrors: [String]) -> [String] {
        var out: [String] = []
        for m in mirrors {
            let url = m.contains(where: \.isWhitespace) ? nil : URL(string: m)
            if !["http", "https"].contains(url?.scheme?.lowercased() ?? "") || (url?.host() ?? "").isEmpty {
                out.append("\(m) is not an http or https URL.")
            } else if let url, !isBareMirror(url, text: m) {
                // dockerd refuses these (moby ValidateMirror).
                out.append("\(m) must have no user name, password, query or fragment.")
            }
        }
        out += duplicates(mirrors).map { "\($0) is in the mirror list twice." }
        return out
    }

    /// True if the URL has no user, password, query or fragment. dockerd allows a path.
    private static func isBareMirror(_ url: URL, text: String) -> Bool {
        url.user(percentEncoded: true) == nil && url.password(percentEncoded: true) == nil
            && !text.contains("?") && !text.contains("#")
    }

    private static func insecureProblems(_ registries: [String]) -> [String] {
        var out: [String] = []
        for r in registries where !isRegistryAddress(r) {
            out.append("\(r) must be host or host:port, or an address range such as 10.0.0.0/8.")
        }
        out += duplicates(registries).map { "\($0) is in the insecure registry list twice." }
        return out
    }

    /// `host`, `host:port` or a CIDR range.
    static func isRegistryAddress(_ s: String) -> Bool {
        if let slash = s.firstIndex(of: "/") {
            let address = String(s[..<slash])
            guard let bits = Int(s[s.index(after: slash)...]), bits >= 0 else { return false }
            var v4 = in_addr()
            var v6 = in6_addr()
            if inet_pton(AF_INET, address, &v4) == 1 { return bits <= 32 }
            if inet_pton(AF_INET6, address, &v6) == 1 { return bits <= 128 }
            return false
        }
        let parts = s.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count <= 2, let host = parts.first.map(String.init) else { return false }
        if parts.count == 2 {
            guard let port = Int(parts[1]), (1...65535).contains(port), parts[1].allSatisfy(\.isNumber) else {
                return false
            }
        }
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789.-")
        return !host.isEmpty && host.allSatisfy(allowed.contains)
            && !".-".contains(host.first ?? "x") && !".-".contains(host.last ?? "x")
    }

    private static func duplicates(_ items: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for i in items where !seen.insert(i).inserted && !out.contains(i) { out.append(i) }
        return out
    }
}
