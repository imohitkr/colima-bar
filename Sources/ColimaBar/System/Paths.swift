import Foundation

/// Filesystem locations. Colima keeps each profile in its own directory under
/// its config folder (`colimaDir`), the "default" profile in .../default.
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
    /// The folder of the proxy sockets of each profile (`PROFILE.sock`).
    static let profilesDir = "\(cacheDir)/profiles"
    /// The proxy socket of one profile, or nil if the name is invalid or the
    /// path is too long for a unix socket (see ProfileSocket).
    static func profileSocket(_ profile: String) -> String? { ProfileSocket.path(dir: profilesDir, profile: profile) }
    static let testcontainersProps = "\(home)/.testcontainers.properties"

    /// The Colima config folder, found once at launch (see `colimaDir(env:home:exists:)`).
    static let colimaDir = colimaDir(
        env: ProcessInfo.processInfo.environment, home: home, exists: FileManager.default.fileExists(atPath:))
    /// Lima's folder of the Colima instances.
    static let limaDir = limaDir(env: ProcessInfo.processInfo.environment, colimaDir: colimaDir)

    /// The Colima config folder, with the rules of Colima 0.10.3
    /// (config/files.go, configBaseDir). The first rule that applies wins:
    /// COLIMA_HOME if it is set and the path exists, then ~/.colima if it
    /// exists, then $XDG_CONFIG_HOME/colima. ColimaBar pins XDG_CONFIG_HOME to
    /// ~/.config for its colima calls (see Shell), so the last rule gives
    /// ~/.config/colima. colima-ctl.sh and uninstall.sh use the same rules.
    static func colimaDir(env: [String: String], home: String, exists: (String) -> Bool) -> String {
        if let dir = env["COLIMA_HOME"], !dir.isEmpty, exists(dir) { return dir }
        let dotColima = "\(home)/.colima"
        if exists(dotColima) { return dotColima }
        return "\(home)/.config/colima"
    }

    /// Lima keeps the Colima instances in LIMA_HOME if it is set, else in
    /// the `_lima` folder of the Colima config folder.
    static func limaDir(env: [String: String], colimaDir: String) -> String {
        if let dir = env["LIMA_HOME"], !dir.isEmpty { return dir }
        return "\(colimaDir)/_lima"
    }

    static func profileDir(_ profile: String) -> String { "\(colimaDir)/\(profile)" }
    static func config(_ profile: String) -> String { "\(profileDir(profile))/colima.yaml" }
    static func socket(_ profile: String) -> String { "\(profileDir(profile))/docker.sock" }
    /// kubectl context Colima creates for a profile.
    static func kubeContext(_ profile: String) -> String { profile == "default" ? "colima" : "colima-\(profile)" }
}
