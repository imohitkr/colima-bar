import Foundation

/// The JSON that `grype -o json` writes. It has only the fields that
/// ColimaBar reads. The title is the first sentence of the description.
struct GrypeReport: Decodable {
    struct Match: Decodable {
        struct Vulnerability: Decodable {
            struct Fix: Decodable {
                let versions: [String]?
            }
            let id: String
            let severity: String?
            let description: String?
            let fix: Fix?
        }
        struct Artifact: Decodable {
            let name: String
            let version: String?
        }
        let vulnerability: Vulnerability
        let artifact: Artifact
    }

    /// The longest title in characters.
    static let titleLimit = 120

    let matches: [Match]?

    var findings: [ImageScanFinding] {
        (matches ?? []).map {
            let versions = ($0.vulnerability.fix?.versions ?? []).filter { !$0.isEmpty }
            return ImageScanFinding(
                vulnID: $0.vulnerability.id, package: $0.artifact.name, installed: $0.artifact.version ?? "",
                fixed: versions.isEmpty ? nil : versions.joined(separator: ", "),
                severity: ImageScanSeverity(tool: $0.vulnerability.severity),
                title: Self.title(of: $0.vulnerability.description))
        }
    }

    /// The first sentence of `text`, cut to `titleLimit` characters.
    static func title(of text: String?) -> String {
        let flat = (text ?? "").split(whereSeparator: \.isNewline).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        var sentence = flat
        if let end = flat.range(of: ". ") { sentence = String(flat[..<end.lowerBound]) }
        sentence = sentence.trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        guard sentence.count > titleLimit else { return sentence }
        return String(sentence.prefix(titleLimit - 1)) + "…"
    }
}
