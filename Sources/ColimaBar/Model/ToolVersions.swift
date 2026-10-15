import Foundation

/// The versions of the tools that Colima needs, from their version output.
struct ToolVersions: Equatable, Sendable {
    var colima: String?
    var lima: String?
    var docker: String?

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
