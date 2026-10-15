import Foundation

/// The parts of the docker CLI config file (`config.json`) that Doctor reads
/// and changes. It never reads `auths`: the registry logins stay private.
struct DockerConfig: Equatable, Sendable {
    /// The credential helper for all registries (`credsStore`).
    var credsStore: String?
    /// The credential helper for each registry (`credHelpers`).
    var credHelpers: [String: String] = [:]
    /// The extra folders for CLI plugins (`cliPluginsExtraDirs`).
    var pluginDirs: [String] = []

    /// The helpers that the file names.
    var helperNames: Set<String> {
        var names = Set(credHelpers.values)
        if let credsStore, !credsStore.isEmpty { names.insert(credsStore) }
        return names
    }

    /// Reads the data of a config file. An empty file is an empty config.
    /// Nil if the data is not a JSON object.
    static func parse(_ data: Data) -> DockerConfig? {
        guard let obj = object(from: data) else { return nil }
        var c = DockerConfig()
        c.credsStore = (obj["credsStore"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        c.credHelpers = (obj["credHelpers"] as? [String: Any])?.compactMapValues { $0 as? String } ?? [:]
        c.pluginDirs = (obj["cliPluginsExtraDirs"] as? [Any])?.compactMap { $0 as? String } ?? []
        return c
    }

    /// The data of a config file with `credsStore` set. All other keys stay.
    /// Nil if the data is not a JSON object.
    static func settingCredsStore(_ name: String, in data: Data) -> Data? {
        guard var obj = object(from: data) else { return nil }
        obj["credsStore"] = name
        return encode(obj)
    }

    /// The data of a config file with `dir` added to `cliPluginsExtraDirs`.
    /// All other keys stay. Nil if the data is not a JSON object.
    static func addingPluginDir(_ dir: String, in data: Data) -> Data? {
        guard var obj = object(from: data) else { return nil }
        var dirs = (obj["cliPluginsExtraDirs"] as? [Any])?.compactMap { $0 as? String } ?? []
        if !dirs.contains(dir) { dirs.append(dir) }
        obj["cliPluginsExtraDirs"] = dirs
        return encode(obj)
    }

    private static func object(from data: Data) -> [String: Any]? {
        if data.allSatisfy({ $0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 }) { return [:] }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func encode(_ obj: [String: Any]) -> Data? {
        try? JSONSerialization.data(
            withJSONObject: obj, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }
}
