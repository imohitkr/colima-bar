import Foundation

/// The two scanners that ColimaBar can run, and their command lines. The
/// functions are pure, so tests check each argument. A scanner reads only a
/// tar file that ColimaBar exported. It gets no docker socket, so it cannot
/// start the VM and it cannot pull an image from a registry.
enum ImageScanner: String, CaseIterable, Sendable {
    case trivy, grype

    /// The name of the program on the search path.
    var binary: String { rawValue }

    var title: String {
        switch self {
        case .trivy: "Trivy"
        case .grype: "Grype"
        }
    }

    /// The command line, with the program first. `offline` means that the Mac
    /// has no internet: the scanner uses the database that it has and makes
    /// no update. Trivy always gets `--offline-scan`, so it makes no Maven
    /// lookup: only the download of the database uses the network.
    func arguments(input: String, output: String, layout: ImageArchiveLayout, offline: Bool) -> [String] {
        switch self {
        case .trivy:
            return [
                "trivy", "image", "--input", input, "--format", "json", "--output", output, "--scanners", "vuln",
                "--list-all-pkgs=false", "--quiet", "--timeout", "14m", "--cache-backend", "memory", "--offline-scan",
            ] + (offline ? ["--skip-db-update", "--skip-java-db-update"] : [])
        case .grype:
            let source = layout == .oci ? "oci-archive" : "docker-archive"
            return ["grype", "\(source):\(input)", "-o", "json", "--file", output, "-q"]
        }
    }

    /// The extra environment of the scanner process. It turns off the
    /// telemetry and the check for a new version. A scanner ignores a
    /// variable that it does not know, but it fails on an argument that it
    /// does not know: thus these options are variables, not arguments. Trivy
    /// keeps the data of an image in memory, so it leaves no copy in its cache folder.
    /// Offline, Grype does not check the age of its database: the check
    /// fails for a database that is older than five days.
    func environment(offline: Bool) -> [String: String] {
        switch self {
        case .trivy:
            return ["TRIVY_DISABLE_TELEMETRY": "true", "TRIVY_SKIP_VERSION_CHECK": "true"]
        case .grype:
            var env = ["GRYPE_CHECK_FOR_APP_UPDATE": "false"]
            if offline {
                env["GRYPE_DB_AUTO_UPDATE"] = "false"
                env["GRYPE_DB_VALIDATE_AGE"] = "false"
            }
            return env
        }
    }

    /// The command that prints the version as JSON.
    var versionArguments: [String] {
        switch self {
        case .trivy: ["trivy", "--version", "-f", "json"]
        case .grype: ["grype", "version", "-o", "json"]
        }
    }

    /// The version in the output of `versionArguments`, or nil.
    func version(from output: String) -> String? {
        guard let start = output.firstIndex(of: "{"),
            let object = try? JSONSerialization.jsonObject(with: Data(output[start...].utf8)) as? [String: Any]
        else { return nil }
        let text = (object["Version"] ?? object["version"]) as? String
        return text.flatMap { $0.isEmpty ? nil : String($0.prefix(40)) }
    }

    /// True if the scanner has a vulnerability database on disk. It is a
    /// guess from the default folders: a wrong guess changes a text only.
    /// `children` lists the names in a folder.
    func hasDatabase(env: [String: String], home: String, children: (String) -> [String], exists: (String) -> Bool)
        -> Bool
    {
        switch self {
        case .trivy:
            let dir = env["TRIVY_CACHE_DIR"].flatMap { $0.isEmpty ? nil : $0 } ?? "\(home)/Library/Caches/trivy"
            return exists("\(dir)/db/metadata.json")
        case .grype:
            let dir =
                env["GRYPE_DB_CACHE_DIR"].flatMap { $0.isEmpty ? nil : $0 } ?? "\(home)/Library/Caches/grype/db"
            return children(dir).contains { exists("\(dir)/\($0)/vulnerability.db") }
        }
    }

    /// Reads the report file. Nil if it is not the JSON of this scanner.
    func parse(_ data: Data) -> [ImageScanFinding]? {
        let decoder = JSONDecoder()
        switch self {
        case .trivy: return (try? decoder.decode(TrivyReport.self, from: data))?.findings
        case .grype: return (try? decoder.decode(GrypeReport.self, from: data))?.findings
        }
    }
}
