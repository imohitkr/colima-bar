import Foundation

/// One entry of `mounts` in colima.yaml: a Mac folder that the VM shares.
struct VMMount: Equatable, Sendable {
    /// A path that starts with `/` or `~`.
    var location: String
    var writable: Bool
    /// The path in the VM, if colima.yaml has one. ColimaBar keeps it.
    var mountPoint: String?

    init(location: String, writable: Bool = false, mountPoint: String? = nil) {
        self.location = location
        self.writable = writable
        self.mountPoint = mountPoint
    }
}
