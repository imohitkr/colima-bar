import Foundation

/// The docker contexts that exist, read from the context folder of the docker
/// CLI (`<config>/contexts/meta/*/meta.json`). Reading starts no process and
/// contacts no daemon. Switching runs `docker context use`, which writes only
/// `currentContext` in the docker config file.
enum DockerContextStore {
    /// The docker config folder: `$DOCKER_CONFIG` if it is set and not empty, else `~/.docker`.
    nonisolated static func configDir(env: [String: String], home: String) -> String {
        if let dir = env["DOCKER_CONFIG"], !dir.isEmpty { return dir }
        return "\(home)/.docker"
    }

    /// The context `default` exists without a folder. docker always lists it.
    nonisolated static let implicitDefault = DockerContextItem(
        name: "default", description: "Current DOCKER_HOST based configuration", endpoint: "")

    /// A name that the CLI could read as an option, or that is empty.
    nonisolated static func isSafe(_ name: String) -> Bool {
        !name.isEmpty && !name.hasPrefix("-") && !name.contains("\n")
    }

    /// The context of one `meta.json`, or nil if it is not a context.
    nonisolated static func parse(meta: Data) -> DockerContextItem? {
        guard let root = (try? JSONSerialization.jsonObject(with: meta)) as? [String: Any],
            let name = root["Name"] as? String, isSafe(name)
        else { return nil }
        let description = ((root["Metadata"] as? [String: Any])?["Description"] as? String) ?? ""
        let docker = ((root["Endpoints"] as? [String: Any])?["docker"] as? [String: Any])?["Host"] as? String
        return DockerContextItem(name: name, description: description, endpoint: docker ?? "")
    }

    /// Every context of the folder, sorted by name, with `default`. A folder
    /// that is missing gives only `default`. A file that is not valid is skipped.
    nonisolated static func list(configDir: String) -> [DockerContextItem] {
        let meta = "\(configDir)/contexts/meta"
        let fm = FileManager.default
        var items: [String: DockerContextItem] = ["default": implicitDefault]
        for folder in (try? fm.contentsOfDirectory(atPath: meta)) ?? [] {
            guard let data = fm.contents(atPath: "\(meta)/\(folder)/meta.json"),
                let item = parse(meta: data)
            else { continue }
            items[item.name] = item
        }
        return items.values.sorted { $0.name < $1.name }
    }

    /// Runs `docker context use NAME`. It refuses a name that is not in
    /// `among` or that starts with `-`, and runs nothing then.
    static func use(_ name: String, among items: [DockerContextItem], run: ContextRunner.Run) async -> Bool {
        guard isSafe(name), items.contains(where: { $0.name == name }) else { return false }
        return await run(["docker", "context", "use", name], 10).ok
    }
}
