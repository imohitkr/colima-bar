import Foundation

/// The rules for Delete Profile. `colima-ctl.sh profile-delete` runs
/// `colima delete --data --force`, which deletes the VM, its disk and the
/// profile folder.
enum ProfileDelete {
    /// Why the profile cannot be deleted now, or nil. A running selected
    /// profile must stop first: the dashboard and auto-start use it.
    static func refusal(profile: String, selected: String, isRunning: Bool) -> String? {
        guard profile == selected, isRunning else { return nil }
        return "Stop the profile \(profile) before you delete it. It is the selected profile, and its VM runs."
    }

    /// The text of the typed confirmation.
    static func warning(profile: String, isRunning: Bool) -> String {
        var lines = [
            "Colima deletes the VM of the profile \(profile) and its disk. All containers, images, volumes and build cache of this profile are lost for good. The profile folder with colima.yaml is also deleted."
        ]
        if isRunning { lines.append("The VM runs now. Its containers stop.") }
        if profile == "default" {
            lines += [
                "",
                "default is the main Colima profile. A plain colima start, and auto-start of the default profile, create it again with an empty disk.",
            ]
        }
        lines += ["", "To continue, type the profile name: \(profile)"]
        return lines.joined(separator: "\n")
    }

    /// True when the typed text is the profile name (see DiskShrink.confirms).
    static func confirms(typed: String, profile: String) -> Bool {
        DiskShrink.confirms(typed: typed, profile: profile)
    }

    /// The profile to select after a delete. If the deleted profile was
    /// selected, use `default`. If `default` itself was deleted, use the
    /// first remaining profile.
    static func nextSelection(deleted: String, selected: String, remaining: [String]) -> String {
        guard deleted == selected else { return selected }
        if deleted != "default" { return "default" }
        return remaining.first { $0 != deleted } ?? "default"
    }
}
