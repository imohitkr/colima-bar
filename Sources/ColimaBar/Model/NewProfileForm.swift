import Foundation

/// The values of the New Profile form. `colima-ctl.sh profile-create` gets
/// them as arguments and runs `colima start` with them.
struct NewProfileForm: Equatable {
    var name = ""
    var cpus: Int
    var memGB: Int
    var diskGB: Int
    var runtime = "docker"

    /// The runtimes that the form offers. Only docker has a docker socket,
    /// so only a docker profile gets auto-start and auto-stop.
    static let runtimes = ["docker", "containerd"]

    /// Colima's own defaults, for a selected profile without known values.
    static let colimaDefaults = (cpus: 2, memGB: 2, diskGB: 100)

    /// The form starts with the CPU, memory and disk of the selected profile.
    static func defaults(from vm: VMInfo) -> NewProfileForm {
        NewProfileForm(
            cpus: vm.cpus > 0 ? vm.cpus : colimaDefaults.cpus,
            // The form offers whole GB. A VM with 2.5 GB starts the form at 2.
            memGB: vm.memGB >= 1 ? Int(vm.memGB) : colimaDefaults.memGB,
            diskGB: vm.diskGB > 0 ? vm.diskGB : colimaDefaults.diskGB)
    }

    /// The choices of a menu: the standard values up to `limit`, and the
    /// current value.
    static func choices(_ standard: [Int], limit: Int, including value: Int) -> [Int] {
        Array(Set(standard.filter { $0 <= limit } + [value])).sorted()
    }

    static let cpuChoices = [1, 2, 4, 6, 8, 10, 12, 16]
    static let memoryChoices = [1, 2, 4, 6, 8, 12, 16, 24, 32, 48, 64]
    static let diskChoices = [20, 40, 60, 100, 150, 200, 300, 500]

    /// Why the form cannot create the profile, or nil.
    func problem(existing: [String]) -> String? {
        if let p = ProfileName.problem(newName: name, existing: existing) { return p }
        if cpus < 1 || memGB < 1 { return "Select at least 1 CPU and 1 GB of memory." }
        if diskGB < DiskShrink.minimumGB { return "Select a disk of \(DiskShrink.minimumGB) GB or more." }
        if !Self.runtimes.contains(runtime) { return "Select the docker or containerd runtime." }
        return nil
    }

    /// The arguments of `colima-ctl.sh profile-create`.
    var arguments: [String] { [String(cpus), String(memGB), String(diskGB), runtime] }
}
