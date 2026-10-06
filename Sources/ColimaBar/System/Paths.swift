import Foundation

/// Filesystem locations. Colima keeps each profile in its own directory under
/// ~/.config/colima (the "default" profile in .../default).
enum Paths {
    static let home = FileManager.default.homeDirectoryForCurrentUser.path
    /// The action backend ships inside the app bundle, so a downloaded copy
    /// works without a separate install step. Unbundled runs use the copy
    /// that older versions installed.
    static let ctl =
        Bundle.main.path(forResource: "colima-ctl", ofType: "sh")
        ?? "\(home)/.local/bin/colima-ctl.sh"
    static let cacheDir = "\(home)/.cache/colima-bar"
    /// Busy marker colima-ctl.sh writes while a VM action runs, per profile.
    static func busy(_ profile: String) -> String { "\(cacheDir)/busy.\(profile)" }
    /// colima-ctl.sh's stderr (colima's own output included) when ColimaBar runs it.
    static let ctlLog = "\(cacheDir)/ctl.log"
    /// The stable socket every docker client is pointed at: ColimaBar's
    /// auto-start proxy while it runs, a symlink to Colima's socket otherwise.
    static let proxySocket = "\(cacheDir)/docker.sock"
    static let testcontainersProps = "\(home)/.testcontainers.properties"

    static func profileDir(_ profile: String) -> String { "\(home)/.config/colima/\(profile)" }
    static func config(_ profile: String) -> String { "\(profileDir(profile))/colima.yaml" }
    static func socket(_ profile: String) -> String { "\(profileDir(profile))/docker.sock" }
    /// kubectl context Colima creates for a profile.
    static func kubeContext(_ profile: String) -> String { profile == "default" ? "colima" : "colima-\(profile)" }
}
