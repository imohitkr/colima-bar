import Foundation
import os

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

    /// The Colima folder and Lima's folder of the Colima instances.
    struct ColimaFolders: Equatable, Sendable {
        let colima: String
        let lima: String
    }

    /// The folders of the last `refreshColimaFolders()`, first found at launch.
    private static let folders = OSAllocatedUnfairLock(initialState: currentColimaFolders())

    /// The Colima config folder (see `colimaDir(env:home:exists:)`). The
    /// model finds it again while the app runs (`refreshColimaFolders()`).
    static var colimaDir: String { folders.withLock { $0.colima } }
    /// Lima's folder of the Colima instances.
    static var limaDir: String { folders.withLock { $0.lima } }

    /// Finds the folders again, with the environment of the app and the
    /// folders that exist now. Returns true if they changed.
    @discardableResult
    static func refreshColimaFolders() -> Bool {
        let now = currentColimaFolders()
        return folders.withLock { old in
            guard old != now else { return false }
            old = now
            return true
        }
    }

    /// True if `refreshColimaFolders()` would change the folders. It costs a
    /// few stat calls.
    static var colimaFoldersMoved: Bool { currentColimaFolders() != folders.withLock { $0 } }

    private static func currentColimaFolders() -> ColimaFolders {
        colimaFolders(
            env: ProcessInfo.processInfo.environment, home: home, exists: FileManager.default.fileExists(atPath:))
    }

    /// The Colima folder and Lima's folder for this environment.
    static func colimaFolders(env: [String: String], home: String, exists: (String) -> Bool) -> ColimaFolders {
        let colima = colimaDir(env: env, home: home, exists: exists)
        return ColimaFolders(colima: colima, lima: limaDir(env: env, colimaDir: colima))
    }

    /// The Colima config folder. The first rule that applies wins:
    ///
    /// 1. COLIMA_HOME, if it is set and the path exists.
    /// 2. ~/.colima, if it exists.
    /// 3. ~/.config/colima, if it exists. Older versions of ColimaBar made
    ///    it, and Colima uses it when the shell sets XDG_CONFIG_HOME.
    /// 4. $XDG_CONFIG_HOME/colima, if XDG_CONFIG_HOME is set.
    /// 5. ~/.colima, the default of Colima on macOS.
    ///
    /// Colima 0.10.3 (config/files.go, configBaseDir) skips rule 3. Thus
    /// ColimaBar gives each colima call COLIMA_HOME (see Shell), so Colima
    /// always uses this folder. colima-ctl.sh and uninstall.sh use the same rules.
    static func colimaDir(env: [String: String], home: String, exists: (String) -> Bool) -> String {
        if let dir = env["COLIMA_HOME"], !dir.isEmpty, exists(dir) { return dir }
        let dotColima = "\(home)/.colima"
        if exists(dotColima) { return dotColima }
        let dotConfig = "\(home)/.config/colima"
        if exists(dotConfig) { return dotConfig }
        if let xdg = env["XDG_CONFIG_HOME"], !xdg.isEmpty { return "\(xdg)/colima" }
        return dotColima
    }

    /// The Colima folder for a colima call. It creates the folder if it is
    /// missing, because Colima skips a COLIMA_HOME that does not exist.
    static func preparedColimaDir() -> String {
        let dir = colimaDir
        if !FileManager.default.fileExists(atPath: dir) {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }
        return dir
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
