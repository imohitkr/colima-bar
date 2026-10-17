import Foundation

/// The tool versions at the last good start of each profile. It is stored as
/// a JSON string in the defaults: `{"work":{"colima":"0.10.3",...}}`.
struct GoodStarts: Equatable, Sendable {
    var records: [String: ToolVersions] = [:]

    /// One entry that can fail to decode without the others.
    private struct Entry: Decodable {
        let versions: ToolVersions?
        init(from decoder: any Decoder) throws { versions = try? ToolVersions(from: decoder) }
    }

    /// Invalid or missing text gives no records. One invalid entry does not
    /// drop the others. `problem` says what was wrong, without the content.
    static func decodeChecked(_ text: String?) -> (records: GoodStarts, problem: String?) {
        guard let text, !text.isEmpty else { return (GoodStarts(), nil) }
        guard let entries = try? JSONDecoder().decode([String: Entry].self, from: Data(text.utf8)) else {
            return (GoodStarts(), "the record of good starts is not valid")
        }
        let good = entries.compactMapValues(\.versions)
        let dropped = entries.count - good.count
        return (
            GoodStarts(records: good), dropped > 0 ? "\(dropped) invalid entries in the record of good starts" : nil
        )
    }

    static func decode(_ text: String?) -> GoodStarts { decodeChecked(text).records }

    /// These records, and the profiles of `names` that have none get `versions`.
    /// A seed never replaces a record.
    func seeded(_ names: [String], with versions: ToolVersions) -> GoodStarts {
        var copy = self
        for n in names where copy.records[n] == nil { copy.records[n] = versions }
        return copy
    }

    /// The JSON text, with sorted keys so equal records give equal text.
    var json: String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        guard let data = try? enc.encode(records) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    /// Only the records of the listed profiles, and of the profiles with a
    /// busy marker: a disk shrink deletes a profile for a short time. An empty
    /// list (`colima list` failed) removes nothing.
    func pruned(keeping listed: Set<String>, busy: Set<String> = []) -> GoodStarts {
        guard !listed.isEmpty else { return self }
        return GoodStarts(records: records.filter { listed.contains($0.key) || busy.contains($0.key) })
    }
}
