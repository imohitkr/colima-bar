import Foundation

/// The rules for a smaller VM disk. A Colima disk cannot shrink in place.
/// Thus `colima-ctl.sh disk-shrink` deletes the VM with all its data and
/// starts it again with a new disk.
enum DiskShrink {
    /// The smallest size in GB. It must be the same as `MIN_DISK` in
    /// colima-ctl.sh: a test checks this.
    static let minimumGB = 10
    /// The sizes in GB that the Shrink menu offers.
    static let choices = [20, 40, 60, 80]

    /// True if the disk can shrink from `current` GB to `size` GB.
    static func isValid(_ size: Int, current: Int) -> Bool {
        size >= minimumGB && size < current
    }

    /// The menu choices that are smaller than the current disk.
    static func options(current: Int) -> [Int] {
        choices.filter { isValid($0, current: current) }
    }

    /// The text of the confirmation alert. `usage` is the disk usage of
    /// the Docker data (the rows of the Disk usage section). It is empty
    /// while the VM is stopped. `running` is the VM state: a stopped VM
    /// starts once to create the new disk, then stops again.
    static func warning(
        profile: String, from: Int, to: Int, usage: [DFRow], kubernetes: Bool, running: Bool,
        volumes: [String] = []
    ) -> String {
        let deletes =
            "Colima cannot shrink a disk in place. Thus ColimaBar deletes the VM of the profile \(profile) and its \(from) GB disk."
        let then =
            running
            ? "Then it starts the VM again with an empty \(to) GB disk and the same settings."
            : "Colima starts the VM once to create the new \(to) GB disk, then stops it again. The other settings stay the same."
        var lines = ["\(deletes) \(then)", ""]
        if usage.isEmpty {
            lines.append(
                "The VM is not running, so ColimaBar cannot show the data on the disk. All containers, images, volumes and build cache are deleted for good."
            )
        } else {
            lines.append("These items are deleted for good:")
            for r in usage { lines.append("• \(r.type): \(r.count), \(ByteFormat.bytes(r.size))") }
            lines.append("Total: \(ByteFormat.bytes(usage.reduce(0) { $0 + $1.size }))")
        }
        if kubernetes { lines.append("The Kubernetes cluster and its data are also deleted.") }
        if let advice = backupAdvice(running: running, volumes: volumes) { lines += ["", advice] }
        lines += ["", "To continue, type the profile name: \(profile)"]
        return lines.joined(separator: "\n")
    }

    /// The most volume names that the warning lists.
    static let listedVolumes = 8

    /// The line about volume backups. While the VM runs, it names the named
    /// volumes (at most 8, then "and N more"), or it is nil if there are none.
    /// A stopped VM shows no volumes, so the line only says what to do.
    static func backupAdvice(running: Bool, volumes: [String]) -> String? {
        guard running else { return "To keep volume data, start the VM and back up the volumes first." }
        guard !volumes.isEmpty else { return nil }
        let shown = volumes.prefix(listedVolumes).joined(separator: ", ")
        let more = volumes.count > listedVolumes ? " and \(volumes.count - listedVolumes) more" : ""
        return "To keep volume data, back up the volumes first: \(shown)\(more)."
    }

    enum Answer: Equatable {
        /// The user typed the profile name and clicked the destructive button.
        case shrink
        case cancel
        /// The user chose **Back Up Volumes…**: the shrink stops.
        case backUpVolumes
    }

    /// The answer for the button that the user clicked. `clicked` counts the
    /// buttons from 0: the destructive button, then **Back Up Volumes…** if
    /// the alert offers it, then **Cancel**. Without the typed profile name,
    /// the destructive button gives no shrink.
    static func answer(clicked: Int, typedOK: Bool, offersBackup: Bool) -> Answer {
        if clicked == 0 { return typedOK ? .shrink : .cancel }
        return offersBackup && clicked == 1 ? .backUpVolumes : .cancel
    }

    /// True when the typed text is the profile name. Only then can the user
    /// click the destructive button. Spaces around the text do not count.
    static func confirms(typed: String, profile: String) -> Bool {
        !profile.isEmpty && typed.trimmingCharacters(in: .whitespaces) == profile
    }
}
