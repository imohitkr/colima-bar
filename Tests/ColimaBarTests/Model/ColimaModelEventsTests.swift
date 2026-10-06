import Foundation
import Testing

@testable import ColimaBar

@Suite struct ColimaModelEventsTests {
    /// Real dockerd events by type. The filter must pass exactly the ones
    /// that `handle` reacts to.
    private let dockerEvents: [String: [String]] = [
        "container": [
            "attach", "commit", "copy", "create", "destroy", "detach", "die", "exec_create: sh",
            "exec_detach", "exec_die", "exec_start: sh -c true", "export", "health_status: healthy",
            "health_status: unhealthy", "kill", "oom", "pause", "rename", "resize", "restart",
            "start", "stop", "top", "unpause", "update", "prune",
        ],
        "image": ["delete", "import", "load", "pull", "push", "save", "tag", "untag", "prune"],
        "volume": ["create", "mount", "unmount", "destroy", "prune"],
        "builder": ["prune"],
        "network": ["create", "connect", "disconnect", "destroy", "remove", "prune"],
        "daemon": ["reload"],
        "plugin": ["enable", "disable", "install", "remove"],
    ]

    /// The /events filter as dockerd reads it.
    private func decoded() throws -> [String: [String]] {
        let obj = try JSONSerialization.jsonObject(with: Data(ColimaModel.eventFilter.utf8))
        return try #require(obj as? [String: [String]])
    }

    /// dockerd's filter: the type is listed and, because "health_status" is
    /// listed, any listed action is a prefix of the action.
    private func filterPasses(_ type: String, _ action: String) throws -> Bool {
        let f = try decoded()
        return (f["type"] ?? []).contains(type) && (f["event"] ?? []).contains { action.hasPrefix($0) }
    }

    @Test func listsTheTypesAndActionsTheHandlerUses() throws {
        let f = try decoded()
        #expect(Set(f.keys) == ["type", "event"])
        #expect(Set(f["type"] ?? []) == ["builder", "container", "image", "volume"])
        let actions = Set(f["event"] ?? [])
        for a in [
            "create", "start", "restart", "die", "stop", "kill", "oom", "pause", "unpause", "rename",
            "destroy", "health_status", "pull", "tag", "untag", "delete", "import", "load", "prune", "commit",
        ] {
            #expect(actions.contains(a), "\(a)")
        }
    }

    @Test func filterPassesExactlyWhatTheHandlerReactsTo() throws {
        for (type, actions) in dockerEvents {
            for a in actions {
                let reacts = !ColimaModel.reaction(type: type, action: a).isEmpty
                #expect(try filterPasses(type, a) == reacts, "\(type) \(a)")
            }
        }
    }

    @Test func prefixMatchKeepsHealthAndDropsExecEvents() throws {
        // dockerd matches every action by prefix because "health_status" is listed.
        let actions = try decoded()["event"] ?? []
        func passes(_ action: String) -> Bool { actions.contains { action.hasPrefix($0) } }
        for a in ["health_status: unhealthy", "health_status: healthy", "die", "oom", "destroy"] {
            #expect(passes(a), "\(a)")
        }
        for a in [
            "exec_create: sh -c true", "exec_start: sh -c true", "exec_die", "exec_detach", "top",
            "attach", "detach", "copy", "export", "resize", "update", "mount", "unmount",
            "archive-path", "extract-to-dir", "push", "save",
        ] {
            #expect(!passes(a), "\(a)")
        }
    }

    @Test func diskEventsMarkDiskDirty() {
        #expect(ColimaModel.reaction(type: "builder", action: "prune") == .disk)
        #expect(ColimaModel.reaction(type: "container", action: "commit") == .disk)
        #expect(ColimaModel.reaction(type: "image", action: "delete").contains(.disk))
        #expect(ColimaModel.reaction(type: "volume", action: "destroy").contains(.disk))
        #expect(ColimaModel.reaction(type: "container", action: "create").contains(.disk))
        #expect(ColimaModel.reaction(type: "container", action: "start") == .containers)
        #expect(ColimaModel.reaction(type: "container", action: "health_status: unhealthy") == .containers)
        #expect(ColimaModel.reaction(type: "container", action: "exec_start: sh").isEmpty)
        #expect(ColimaModel.reaction(type: "network", action: "prune").isEmpty)
    }

    @Test func streamThreadDropsExecAndTop() {
        #expect(ColimaModel.ignores(action: "exec_start: /bin/sh -c curl"))
        #expect(ColimaModel.ignores(action: "top"))
        #expect(!ColimaModel.ignores(action: "die"))
        #expect(!ColimaModel.ignores(action: "health_status: unhealthy"))
    }
}
