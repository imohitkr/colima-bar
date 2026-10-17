import Foundation

/// The versions of the tools that Colima needs, from their version output.
struct ToolVersions: Equatable, Sendable, Codable {
    var colima: String?
    var lima: String?
    var docker: String?
    /// The macOS version, for example "15.6.1". Doctor shows it. No dialog does.
    var macOS: String?

    /// The record of a good start has no docker: the docker CLI is only a client.
    enum CodingKeys: String, CodingKey { case colima, lima, macOS }

    /// "15.6.1" from the version of the system.
    static func macOS(_ v: OperatingSystemVersion) -> String {
        "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }

    /// The changes from `old` (the last good start) to these versions, for
    /// Colima, Lima and macOS. A side that is nil, "unknown" or not a version
    /// gives no change. Equal versions, also with other build suffixes, give none.
    func changed(from old: ToolVersions) -> [VersionChange] {
        [
            (VersionChange.Tool.colima, old.colima, colima), (.lima, old.lima, lima), (.macOS, old.macOS, macOS),
        ].compactMap { tool, before, after in
            guard let before, let after, let kind = VersionChange.kind(from: before, to: after) else { return nil }
            return VersionChange(tool: tool, from: Version.strip(before), to: Version.strip(after), kind: kind)
        }
    }

    /// The first dotted version in the output, for example "0.10.3" from
    /// "colima version 0.10.3", "2.2.1" from "limactl version 2.2.1" and
    /// "29.0.1" from "Docker version 29.0.1, build abc".
    static func version(in output: String) -> String? {
        for line in output.split(whereSeparator: \.isNewline) {
            for word in line.split(separator: " ") {
                var w = String(word)
                if w.hasSuffix(",") { w.removeLast() }
                if let parts = Version.parts(w), parts.count >= 2 { return Version.strip(w) }
            }
        }
        return nil
    }

    /// Lima before 2.1 does not set the clock of the VM after a system sleep.
    var limaIsOld: Bool {
        guard let lima, Version.parts(lima) != nil else { return false }
        return Version.isNewer("2.1", than: lima)
    }
}
