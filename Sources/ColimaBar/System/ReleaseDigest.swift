import CryptoKit
import Foundation

/// The SHA-256 digest of a release file. GitHub gives each release asset a
/// `digest` of the form `sha256:` and 64 hex digits. ColimaBar hashes the
/// download while it writes the file, then compares the two values.
struct ReleaseDigest {
    private var hasher = SHA256()
    private(set) var count = 0

    /// Adds the next chunk of the file. The chunk size does not change the result.
    mutating func update(_ chunk: Data) {
        hasher.update(data: chunk)
        count += chunk.count
    }

    /// The digest of all chunks so far, as 64 lowercase hex digits.
    func hex() -> String {
        hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// The 64 lowercase hex digits of an API `digest` value, or nil if the
    /// value is not `sha256:` and exactly 64 hex digits.
    static func parse(_ value: String) -> String? {
        guard value.hasPrefix("sha256:") else { return nil }
        let hex = value.dropFirst("sha256:".count)
        guard hex.utf8.count == 64,
            hex.utf8.allSatisfy({
                ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66) || ($0 >= 0x41 && $0 <= 0x46)
            })
        else { return nil }
        return hex.lowercased()
    }

    /// True if both values are the same digest. The case does not matter.
    static func matches(_ a: String, _ b: String) -> Bool {
        a.count == 64 && a.lowercased() == b.lowercased()
    }
}
