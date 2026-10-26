import Foundation

/// Names of Kubernetes namespaces.
enum KubeNamespace {
    /// True for a DNS-1123 label: 1 to 63 characters, lower-case letters,
    /// digits and `-`, starting and ending with a letter or digit.
    static func isValid(_ name: String) -> Bool {
        guard (1...63).contains(name.utf8.count) else { return false }
        let ok = { (c: UInt8) in (c >= 0x61 && c <= 0x7A) || (c >= 0x30 && c <= 0x39) }
        let bytes = Array(name.utf8)
        guard ok(bytes[0]), ok(bytes[bytes.count - 1]) else { return false }
        return bytes.allSatisfy { ok($0) || $0 == 0x2D }
    }

    /// The names in the output of `kubectl get namespaces -o name`
    /// (`namespace/NAME` lines), sorted. A line that is not valid is skipped.
    static func parse(listing: String) -> [String] {
        let prefix = "namespace/"
        let names = listing.split(whereSeparator: \.isNewline).compactMap { line -> String? in
            let text = line.trimmingCharacters(in: .whitespaces)
            guard text.hasPrefix(prefix) else { return nil }
            let name = String(text.dropFirst(prefix.count))
            return isValid(name) ? name : nil
        }
        return Array(Set(names)).sorted()
    }
}
