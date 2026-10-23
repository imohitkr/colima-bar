import Foundation

/// What a VM type change needs to know, as pure values: what ColimaBar can
/// back up, which images to save, how much space the backups need, and the
/// text of the confirmation. `ColimaModel+VMRecreate` runs the plan.
struct VMRecreatePlan: Equatable {
    struct Inputs {
        var profile: String
        /// colima.yaml now.
        var current: VMSettings.Read
        var target: (vmType: String, mountType: String)
        var running: Bool
        var hasDockerSocket: Bool
        /// The Docker data is on its own Lima disk, which Colima keeps.
        var dataDiskKept: Bool
        var volumes: [VolumeRow]
        var images: [ImageRow]
    }

    /// ColimaBar can back up only while a docker VM runs.
    let canBackUp: Bool
    /// The named volumes, sorted by name.
    let volumes: [VolumeRow]
    /// The images that containers use: `repo:tag`, or the full id of an image
    /// with no tag. The helper image of ColimaBar is not in the list.
    let imageRefs: [String]
    let volumeBytes: Double
    let imageBytes: Double
    let backUpByDefault: Bool
    let saveImagesByDefault: Bool

    static func make(_ i: Inputs) -> VMRecreatePlan {
        let canBackUp = i.running && i.hasDockerSocket
        let named = VolumeRow.named(i.volumes)
        let used = i.images.filter { $0.containers > 0 && "\($0.repo):\($0.tag)" != HelperImage.tag }
        var refs: [String] = []
        for image in used {
            let ref = image.dangling ? image.id : image.ref
            if !refs.contains(ref) { refs.append(ref) }
        }
        var seen = Set<String>()
        let imageBytes = used.filter { seen.insert($0.id).inserted }.reduce(0) { $0 + $1.size }
        return VMRecreatePlan(
            canBackUp: canBackUp, volumes: named, imageRefs: refs,
            volumeBytes: named.reduce(0) { $0 + $1.size }, imageBytes: imageBytes,
            backUpByDefault: canBackUp && !named.isEmpty,
            saveImagesByDefault: canBackUp && !i.dataDiskKept && !refs.isEmpty)
    }

    /// The bytes that the folder needs for the chosen parts: their size, 10%
    /// more and 2 GiB. It is 0 if nothing is chosen.
    func neededBytes(backUp: Bool, saveImages: Bool) -> Int64 {
        let size = (backUp ? volumeBytes : 0) + (saveImages ? imageBytes : 0)
        guard backUp || saveImages else { return 0 }
        return Int64(size * 1.1) + 2 * ByteFormat.bytesPerGiB
    }

    // MARK: - Data disk

    /// True if the Docker data of the profile is on its own Lima disk, which
    /// `colima delete` keeps. The rule is the one of `data_disk_kept` in
    /// colima-ctl.sh: the disk folder exists and the store of Colima says that
    /// the disk has a file system.
    static func dataDiskKept(
        profile: String, colimaDir: String, limaDir: String,
        fileExists: (String) -> Bool = FileManager.default.fileExists(atPath:),
        read: (String) -> String? = { try? String(contentsOfFile: $0, encoding: .utf8) }
    ) -> Bool {
        let instance = Paths.limaInstance(profile)
        guard fileExists("\(limaDir)/_disks/\(instance)") else { return false }
        guard let store = read("\(colimaDir)/_store/\(instance).json") else { return false }
        return store.filter { !" \t\r\n".contains($0) }.contains("\"disk_formatted\":true")
    }

    // MARK: - Confirmation

    static let listedVolumes = 8

    /// The text of the confirmation alert.
    static func warning(_ i: Inputs, plan: VMRecreatePlan) -> String {
        let from = VMTypeRules.effective(vmType: i.current.vmType, mountType: i.current.mountType)
        // Name only what changes: "from vz to vz" reads like a mistake.
        var changes: [String] = []
        if from.vmType != i.target.vmType { changes.append("the VM type from \(from.vmType) to \(i.target.vmType)") }
        if from.mountType != i.target.mountType {
            changes.append("the mount type from \(from.mountType) to \(i.target.mountType)")
        }
        let what = changes.isEmpty ? "the VM" : changes.joined(separator: " and ")
        var lines = [
            "ColimaBar changes \(what). Colima cannot change this on an existing VM. Thus Colima deletes the VM and creates it again with the same other settings."
        ]
        if i.dataDiskKept {
            lines.append(
                "Colima keeps the Docker data disk. Images, containers and volumes should stay. Back up the volumes anyway, in case the new VM cannot use the disk."
            )
            if i.current.kubernetes {
                lines.append("Kubernetes starts again. Its data stays on the data disk.")
            }
        } else {
            var lost =
                "This VM has no separate Docker data disk. All containers, images, volumes and build cache are deleted for good."
            if i.current.kubernetes { lost += " The Kubernetes cluster and its data are also deleted." }
            lines.append(lost)
        }
        if i.current.rosetta, i.target.vmType == "qemu" {
            lines.append("Rosetta turns off. It needs the vz VM type.")
        }
        lines.append(
            i.running
                ? "The VM restarts. Running containers stop."
                : "Colima starts the VM once to create it, then stops it again.")
        if !plan.canBackUp {
            var text = "ColimaBar can back up only while a docker VM runs."
            if !i.dataDiskKept { text += " Start the VM first to keep your data." }
            lines.append(text)
        }
        lines.append("ColimaBar does not create containers again. Run docker compose up again if you need to.")
        lines += ["", "To continue, type the profile name: \(i.profile)"]
        return lines.joined(separator: "\n")
    }

    /// True when the typed text is the profile name.
    static func confirms(typed: String, profile: String) -> Bool {
        DiskShrink.confirms(typed: typed, profile: profile)
    }

    enum Answer: Equatable {
        case recreate(backUp: Bool, saveImages: Bool)
        case cancel
    }

    /// The answer for the button that the user clicked. `clicked` counts the
    /// buttons from 0: the destructive button, then **Cancel**. Without the
    /// typed profile name, the destructive button gives no recreate.
    static func answer(clicked: Int, typedOK: Bool, backUp: Bool, saveImages: Bool) -> Answer {
        clicked == 0 && typedOK ? .recreate(backUp: backUp, saveImages: saveImages) : .cancel
    }
}
