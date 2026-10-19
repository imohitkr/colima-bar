import Foundation

/// The Compose project of a container, read from its `com.docker.compose.*`
/// labels. `ColimaBar` runs `docker compose` with these values, so the
/// checks here match the checks of `colima-ctl.sh`.
struct ComposeProject: Equatable, Sendable {
    let name: String
    /// The project folder, an absolute path.
    let directory: String
    /// The Compose files, absolute paths. At least 1 and at most 16.
    let configFiles: [String]
    /// The env files, absolute paths. At most 16.
    let environmentFiles: [String]

    static let maxFiles = 16
    static let maxPathBytes = 1024

    static func from(labels: [String: String]) -> ComposeProject? {
        guard let name = labels["com.docker.compose.project"], isValid(name: name),
            let dir = path(labels["com.docker.compose.project.working_dir"]),
            let list = labels["com.docker.compose.project.config_files"]
        else { return nil }
        let files = list.split(separator: ",", omittingEmptySubsequences: false).map { path(String($0)) }
        guard (1...maxFiles).contains(files.count), files.allSatisfy({ $0 != nil }) else { return nil }
        var env: [String] = []
        if let raw = labels["com.docker.compose.project.environment_file"], !raw.isEmpty {
            // An env file that fails the check makes the project unusable.
            let parsed = raw.split(separator: ",", omittingEmptySubsequences: false).map { path(String($0)) }
            guard parsed.count <= maxFiles, parsed.allSatisfy({ $0 != nil }) else { return nil }
            env = parsed.compactMap { $0 }
        }
        return ComposeProject(name: name, directory: dir, configFiles: files.compactMap { $0 }, environmentFiles: env)
    }

    /// Compose writes lower-case names with letters, digits, `-` and `_`.
    static func isValid(name: String) -> Bool {
        name.range(of: #"\A[a-z0-9][a-z0-9_-]{0,62}\z"#, options: .regularExpression) != nil
    }

    /// The arguments after the action name of `colima-ctl.sh compose-*`:
    /// `NAME DIR NENV ENV... FILE...`. `NENV` is the number of env files.
    func ctlArgs() -> [String] {
        [name, directory, String(environmentFiles.count)] + environmentFiles + configFiles
    }

    /// The Compose files and the env file that `exists` does not find.
    func missingFiles(exists: (String) -> Bool) -> [String] {
        (configFiles + environmentFiles).filter { !exists($0) }
    }

    /// An absolute path with no `..`, no control character and at most 1024
    /// bytes, in its standard form. Else nil.
    private static func path(_ raw: String?) -> String? {
        guard let raw, raw.hasPrefix("/"), raw.utf8.count <= maxPathBytes,
            !raw.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F })
        else { return nil }
        let parts = raw.split(separator: "/", omittingEmptySubsequences: true)
        guard !parts.contains("..") else { return nil }
        return "/" + parts.filter { $0 != "." }.joined(separator: "/")
    }
}
