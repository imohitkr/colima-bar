import Foundation

/// The checks for the debug shell. A debug shell is built only from a
/// checked hex ID and a checked image name. `colima-ctl.sh ctr-debug` checks
/// both again.
enum DebugShell {
    static let defaultImage = "busybox:latest"

    /// True for the full ID of a container: 64 lowercase hex characters.
    /// A name or a short ID is not valid.
    static func isValidID(_ s: String) -> Bool {
        s.utf8.count == 64 && s.utf8.allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66) }
    }

    /// True for an image name of 1 to 255 characters. The first character is
    /// a lowercase letter or a digit, so a value never reads as a flag. The
    /// others are letters, digits and `. _ / : @ -`.
    static func isValidImage(_ s: String) -> Bool {
        let bytes = Array(s.utf8)
        guard (1...255).contains(bytes.count), let first = bytes.first else { return false }
        let lower = first >= 0x61 && first <= 0x7a
        let digit = first >= 0x30 && first <= 0x39
        guard lower || digit else { return false }
        return bytes.allSatisfy {
            ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x41 && $0 <= 0x5a) || ($0 >= 0x61 && $0 <= 0x7a)
                || "._/:@-".utf8.contains($0)
        }
    }

    /// The image to use for a stored setting. An unset or empty value gives
    /// the default image. An invalid value gives the default image and sets
    /// `invalid`, so the caller can tell the user.
    static func image(stored: String?) -> (image: String, invalid: Bool) {
        let value = (stored ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty { return (defaultImage, false) }
        return isValidImage(value) ? (value, false) : (defaultImage, true)
    }

    /// The name of the sidecar container: the first 12 characters of the ID.
    static func sidecarName(id: String) -> String { "\(sidecarPrefix)\(id.prefix(12))" }

    static let sidecarPrefix = "colimabar-debug-"

    /// True for the name of a debug shell container: the prefix and 12
    /// lowercase hex characters, nothing else.
    static func isSidecar(name: String?) -> Bool {
        guard let name, name.hasPrefix(sidecarPrefix) else { return false }
        let rest = name.dropFirst(sidecarPrefix.count)
        return rest.utf8.count == 12 && isValidHex(String(rest))
    }

    private static func isValidHex(_ s: String) -> Bool {
        s.utf8.allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66) }
    }

    /// The arguments of `colima-ctl.sh ctr-debug`, or nil if the ID or the
    /// image is not valid.
    static func ctlArgs(id: String, image: String) -> [String]? {
        isValidID(id) && isValidImage(image) ? [id, image] : nil
    }
}
