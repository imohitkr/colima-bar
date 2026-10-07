import Foundation

extension ColimaModel {
    /// What an event makes `handle` do.
    struct EventReaction: OptionSet, Sendable {
        let rawValue: Int
        static let containers = EventReaction(rawValue: 1)  // reload the container list
        static let disk = EventReaction(rawValue: 2)  // df, images and volumes are stale
        static let savedLogs = EventReaction(rawValue: 4)  // RemovedLogKeeper needs it
    }

    /// The events that `handle` reacts to, by type and action. The /events
    /// filter is built from this table, so the filter and the handler cannot
    /// drift apart. dockerd drops all other events, so healthcheck exec events
    /// (several per second with many containers) never wake the app.
    nonisolated static let eventReactions: [String: [String: EventReaction]] = [
        "container": [
            "create": [.containers, .disk], "destroy": [.containers, .disk, .savedLogs],
            "prune": [.containers, .disk], "start": [.containers, .savedLogs], "restart": .containers,
            "die": [.containers, .savedLogs], "kill": .containers, "stop": .containers,
            "oom": [.containers, .savedLogs], "pause": .containers, "unpause": .containers,
            "rename": .containers, "health_status": .containers,
            // An untagged `docker commit` sends only this event.
            "commit": .disk,
        ],
        "image": [
            "pull": [.containers, .disk], "tag": [.containers, .disk], "untag": [.containers, .disk],
            "delete": [.containers, .disk], "import": [.containers, .disk], "load": [.containers, .disk],
            "prune": [.containers, .disk],
        ],
        "volume": [
            "create": [.containers, .disk], "destroy": [.containers, .disk], "prune": [.containers, .disk],
        ],
        // `docker builder prune` changes the build cache.
        "builder": ["prune": .disk],
    ]

    /// The reaction to one event. Health events have a status after a colon
    /// ("health_status: unhealthy"); the part before the colon decides.
    nonisolated static func reaction(type: String, action: String) -> EventReaction {
        guard let actions = eventReactions[type] else { return [] }
        if let r = actions[action] { return r }
        guard let colon = action.firstIndex(of: ":") else { return [] }
        return actions[String(action[..<colon])] ?? []
    }

    /// "health_status" makes dockerd match every action by prefix, so it also
    /// matches "health_status: unhealthy". No other action here is a prefix
    /// of an unwanted one.
    nonisolated static let eventTypes = eventReactions.keys.sorted()
    nonisolated static let eventActions = Set(eventReactions.values.flatMap(\.keys)).sorted()

    nonisolated static var eventFilter: String {
        let f = ["type": eventTypes, "event": eventActions]
        let data = (try? JSONSerialization.data(withJSONObject: f, options: [.sortedKeys])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    /// Events that change nothing ColimaBar shows. The server filter already
    /// drops them; this check runs on the stream thread in case one slips through.
    nonisolated static func ignores(action: String) -> Bool {
        action.hasPrefix("exec_") || action == "top"
    }
}
