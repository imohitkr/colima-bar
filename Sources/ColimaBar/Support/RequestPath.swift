import Foundation

/// Hides the names in the path of a docker API request, so a log line says
/// what the request does but not which container, image, volume or network
/// it is about. Pure.
enum RequestPath {
    /// The collections of the docker API that have names or ids after them.
    private static let collections: Set<String> = [
        "containers", "images", "volumes", "networks", "exec", "plugins", "distribution", "services", "tasks",
        "nodes", "secrets", "configs", "swarm",
    ]
    /// The segments after a collection that are actions, not names.
    private static let collectionActions: Set<String> = [
        "json", "create", "prune", "get", "load", "search", "build", "pull", "privileges", "set", "disable",
        "enable", "upgrade", "init", "join", "leave", "update", "unlock", "unlockkey", "ls", "list",
    ]
    /// The segments that end an image reference.
    private static let imageVerbs: Set<String> = ["json", "history", "push", "tag", "get"]
    static let placeholder = "{name}"

    /// `path` with each name replaced by `{name}`. The version prefix
    /// (`/v1.54`) stays. An image reference can hold `/` and `:`, so it ends
    /// at the next action segment or at the end of the path.
    static func hideNames(_ path: String) -> String {
        var segments = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        var i = 0
        if segments.count > 1, segments[0].isEmpty { i = 1 }
        if i < segments.count, segments[i].hasPrefix("v"), segments[i].dropFirst().first?.isNumber == true { i += 1 }
        guard i + 1 < segments.count, collections.contains(segments[i]) else { return path }
        let collection = segments[i]
        let start = i + 1
        guard !segments[start].isEmpty, !collectionActions.contains(segments[start]) else { return path }
        if collection == "images" || collection == "distribution" {
            let end = (start + 1..<segments.count).first { imageVerbs.contains(segments[$0]) } ?? segments.count
            segments.replaceSubrange(start..<end, with: [placeholder])
        } else {
            segments[start] = placeholder
        }
        return segments.joined(separator: "/")
    }
}
