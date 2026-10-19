import Foundation

/// The names around a volume backup: the default file name, and the rules
/// for the name of a new volume.
enum VolumeBackupName {
    /// The longest part of a file name that comes from the volume name.
    static let maxBase = 64
    /// The longest name of a volume that ColimaBar creates.
    static let maxVolume = 128

    /// `VOLUME-yyyyMMdd-HHmmss.tar`. A character outside `A-Z a-z 0-9 _ . -`
    /// becomes `_`. An anonymous volume has a 64-character hex name, so only
    /// the first 12 characters are used.
    static func fileName(
        volume: String, isAnonymous: Bool, date: Date, timeZone: TimeZone = .current
    ) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = timeZone
        f.dateFormat = "yyyyMMdd-HHmmss"
        let source = isAnonymous ? String(volume.prefix(12)) : volume
        var base = String(sanitize(source).prefix(maxBase))
        if base.isEmpty { base = "volume" }
        return "\(base)-\(f.string(from: date)).tar"
    }

    /// The file names for several volumes. Two volumes can give the same name
    /// (`a/b` and `a_b`), and a Mac compares file names without case. The
    /// later name gets `-2`, `-3` before `.tar`.
    static func fileNames(
        for volumes: [(name: String, isAnonymous: Bool)], date: Date, timeZone: TimeZone = .current
    ) -> [String] {
        var used = Set<String>()
        return volumes.map { v in
            let name = fileName(volume: v.name, isAnonymous: v.isAnonymous, date: date, timeZone: timeZone)
            var candidate = name
            var n = 2
            while !used.insert(candidate.lowercased()).inserted {
                candidate = String(name.dropLast(".tar".count)) + "-\(n).tar"
                n += 1
            }
            return candidate
        }
    }

    static func sanitize(_ text: String) -> String {
        String(
            text.unicodeScalars.map { s in
                isAllowed(s) ? Character(s) : "_"
            })
    }

    /// True for a name that Docker accepts for a new named volume: a letter
    /// or digit, then letters, digits and `_ . -`, with 2 to 128 characters.
    static func isValidNewName(_ name: String) -> Bool {
        let scalars = Array(name.unicodeScalars)
        guard (2...maxVolume).contains(scalars.count), let first = scalars.first else { return false }
        return isAlphanumeric(first) && scalars.allSatisfy(isAllowed)
    }

    /// The name that the Restore to a new volume form starts with: the
    /// original name, or `NAME-restored` if a volume has the original name.
    static func suggestion(original: String?, isTaken: Bool) -> String {
        let clean = sanitize(original ?? "")
        let base = isValidNewName(clean) ? clean : "volume"
        guard isTaken else { return base }
        return String(base.prefix(maxVolume - "-restored".count)) + "-restored"
    }

    private static func isAlphanumeric(_ s: Unicode.Scalar) -> Bool {
        (s.value >= 0x30 && s.value <= 0x39) || (s.value >= 0x41 && s.value <= 0x5A)
            || (s.value >= 0x61 && s.value <= 0x7A)
    }

    private static func isAllowed(_ s: Unicode.Scalar) -> Bool {
        isAlphanumeric(s) || s == "_" || s == "." || s == "-"
    }
}
