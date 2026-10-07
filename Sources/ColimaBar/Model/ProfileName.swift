import Foundation

/// The rules for Colima profile names.
///
/// `isValid` is the check that colima-ctl.sh applies to every action. The
/// rules for a new name are stricter, because Colima, Lima and the docker
/// context use the name in paths, host names and context names.
/// colima-ctl.sh `profile-create` applies the same rules: a test checks this.
enum ProfileName {
    /// The longest name that New Profile accepts. Lima puts the name into
    /// unix socket paths, which hold at most 103 bytes.
    static let maxNewLength = 30

    /// True if colima-ctl.sh accepts the name: ASCII letters, digits, ".",
    /// "_" and "-", not empty, and no leading ".". A leading "." allows "."
    /// and "..", which point outside the profile folder.
    static func isValid(_ name: String) -> Bool {
        !name.isEmpty && !name.hasPrefix(".")
            && name.utf8.allSatisfy { isAlnum($0) || $0 == 46 || $0 == 95 || $0 == 45 }
    }

    /// Why New Profile refuses `name`, or nil if the name is good.
    /// `existing` holds the names of the current profiles. The Mac file
    /// system ignores case, so "Work" and "work" are the same profile.
    static func problem(newName name: String, existing: [String]) -> String? {
        if name.isEmpty { return "Type a profile name." }
        if name.utf8.count > maxNewLength { return "Use \(maxNewLength) characters or fewer." }
        let chars = Array(name.utf8)
        let lowerOrDigit: (UInt8) -> Bool = { (97...122).contains($0) || (48...57).contains($0) }
        guard chars.allSatisfy({ lowerOrDigit($0) || $0 == 45 }),
            let first = chars.first, let last = chars.last, first != 45, last != 45,
            !name.contains("--")
        else { return "Use lowercase letters, digits and single hyphens. Start and end with a letter or a digit." }
        if name == "default" { return "The name default belongs to the default profile." }
        // Colima maps "colima" to "default" and removes a "colima-" prefix:
        // "colima-work" means "work".
        if name == "colima" || name.hasPrefix("colima-") {
            return "Colima reads this name as a different profile. Do not use colima or names that start with colima-."
        }
        if existing.contains(where: { $0.lowercased() == name }) { return "A profile with this name exists." }
        return nil
    }

    private static func isAlnum(_ c: UInt8) -> Bool {
        (65...90).contains(c) || (97...122).contains(c) || (48...57).contains(c)
    }
}
