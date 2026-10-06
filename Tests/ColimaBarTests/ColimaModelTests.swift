import Foundation
import Testing

@testable import ColimaBar

@Suite struct DFGateUrgentTests {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func ask(_ g: inout DFGate, at s: TimeInterval, urgent: Bool = false) -> DFGate.Step {
        g.request(now: t0.addingTimeInterval(s), urgent: urgent)
    }
    private func done(_ g: inout DFGate, at s: TimeInterval) -> DFGate.Step { g.end(now: t0.addingTimeInterval(s)) }

    @Test func urgentSkipsTheGap() {
        var g = DFGate()
        _ = ask(&g, at: 0)
        g.begin()
        _ = done(&g, at: 1)
        let step = ask(&g, at: 2, urgent: true)
        #expect(step == .run(after: 0))
    }

    @Test func urgentReplacesAWaitingRun() {
        var g = DFGate()
        _ = ask(&g, at: 0)
        g.begin()
        _ = done(&g, at: 1)
        let normal = ask(&g, at: 2)
        let waiting = g.ticket
        let urgent = ask(&g, at: 3, urgent: true)
        #expect(normal == .run(after: 29))
        #expect(urgent == .run(after: 0))
        #expect(g.ticket != waiting, "the waiting run must see that it was replaced")
        // Another normal request joins the urgent run.
        let joined = ask(&g, at: 3)
        #expect(joined == .none)
    }

    @Test func urgentWaitsForTheRunInFlightThenRunsAtOnce() {
        var g = DFGate()
        _ = ask(&g, at: 0)
        g.begin()
        let during = ask(&g, at: 1, urgent: true)
        let after = done(&g, at: 5)
        #expect(during == .none)  // only one df in flight
        #expect(after == .run(after: 0))  // no 30 s gap
    }

    @Test func normalRequestDuringARunStillWaitsForTheGap() {
        var g = DFGate()
        _ = ask(&g, at: 0)
        g.begin()
        _ = ask(&g, at: 1)
        let after = done(&g, at: 5)
        #expect(after == .run(after: 30))
    }

    @Test func skipForgetsAnUrgentRequest() {
        var g = DFGate()
        _ = ask(&g, at: 0)
        g.begin()
        _ = ask(&g, at: 1, urgent: true)
        g.skip()
        #expect(!g.again && !g.againUrgent)
    }

    @Test func diskActionsAreUrgent() {
        for a in ["img-rm", "vol-rm", "prune", "img-pull", "ctr-rm", "stop-all"] {
            #expect(ColimaModel.changesDisk(a), "\(a)")
        }
        for a in ["config", "logs", "copy-env", "start", "ssh"] { #expect(!ColimaModel.changesDisk(a), "\(a)") }
    }
}

@Suite struct EventReactionTests {
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

    /// dockerd's filter: the type is listed and, because "health_status" is
    /// listed, any listed action is a prefix of the action.
    private func filterPasses(_ type: String, _ action: String) throws -> Bool {
        let obj = try JSONSerialization.jsonObject(with: Data(ColimaModel.eventFilter.utf8))
        let f = try #require(obj as? [String: [String]])
        return (f["type"] ?? []).contains(type) && (f["event"] ?? []).contains { action.hasPrefix($0) }
    }

    @Test func filterIsBuiltFromTheTable() {
        #expect(Set(ColimaModel.eventTypes) == Set(ColimaModel.eventReactions.keys))
        #expect(Set(ColimaModel.eventActions) == Set(ColimaModel.eventReactions.values.flatMap(\.keys)))
        #expect(ColimaModel.eventTypes.contains("builder"))
        #expect(ColimaModel.eventActions.contains("commit"))
    }

    @Test func filterPassesExactlyWhatTheHandlerReactsTo() throws {
        for (type, actions) in dockerEvents {
            for a in actions {
                let reacts = !ColimaModel.reaction(type: type, action: a).isEmpty
                #expect(try filterPasses(type, a) == reacts, "\(type) \(a)")
            }
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
}

@Suite struct StatusOrderTests {
    @Test func olderResultAfterANewerOneIsDropped() {
        var o = LatestOnly()
        let a = o.begin()
        let b = o.begin()
        let newer = o.apply(b)  // newer "Stopped" applies first
        let older = o.apply(a)  // older "Running" ends later: dropped
        #expect(newer && !older)
        #expect(o.isLatestApplied(b))
        #expect(!o.isLatestApplied(a))
    }

    @Test func olderResultAppliesWhenTheNewerOneGaveNothing() {
        var o = LatestOnly()
        let a = o.begin()
        _ = o.begin()  // fails, never applies
        let applied = o.apply(a)
        #expect(applied)
    }

    @Test func laterStepOfAnOlderCallIsDropped() {
        var o = LatestOnly()
        let a = o.begin()
        let first = o.apply(a)  // `colima list` applied, `colima status` runs
        let b = o.begin()
        let second = o.apply(b)
        #expect(first && second)
        #expect(!o.isLatestApplied(a))
    }
}

@Suite struct StartProbeTests {
    @Test func pgrepOnlyMatchesThisUser() {
        #expect(ColimaModel.pgrepArguments(uid: 501) == ["-U", "501", "-f", "colima (start|restart)"])
    }
}
