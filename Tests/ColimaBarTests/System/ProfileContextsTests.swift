import Testing

@testable import ColimaBar

@Suite struct ProfileContextsTests {
    private typealias Ctx = ProfileContexts.Context
    private let ours = "ColimaBar profile work (auto-starts Colima)"

    @Test func contextNamesUseThePrefix() {
        #expect(ProfileContexts.name("work") == "colimabar-work")
        #expect(ProfileContexts.description("work") == ours)
    }

    @Test func parseReadsNameEndpointAndDescription() {
        let out =
            "colimabar\tunix:///s/docker.sock\tColimaBar (auto-starts Colima)\nremote\tssh://x\t\ndefault\t\tsome\ttabs\n"
        #expect(
            ProfileContexts.parse(out) == [
                Ctx(
                    name: "colimabar", endpoint: "unix:///s/docker.sock", description: "ColimaBar (auto-starts Colima)"),
                Ctx(name: "remote", endpoint: "ssh://x", description: ""),
                Ctx(name: "default", endpoint: "", description: "some\ttabs"),
            ])
    }

    @Test func missingContextsAreCreated() {
        let steps = ProfileContexts.plan(existing: [], wanted: ["work": "unix:///p/work.sock"])
        #expect(steps == [.create(name: "colimabar-work", host: "unix:///p/work.sock", description: ours)])
        #expect(
            ProfileContexts.arguments(steps[0]) == [
                "docker", "context", "create", "colimabar-work", "--description", ours, "--docker",
                "host=unix:///p/work.sock",
            ])
    }

    @Test func ourContextsAreUpdatedOrRemoved() {
        let existing = [
            Ctx(name: "colimabar-work", endpoint: "unix:///old/work.sock", description: ours),
            Ctx(name: "colimabar-gone", endpoint: "unix:///p/gone.sock", description: "ColimaBar profile gone"),
            Ctx(name: "colimabar-ok", endpoint: "unix:///p/ok.sock", description: "ColimaBar profile ok"),
        ]
        let steps = ProfileContexts.plan(
            existing: existing, wanted: ["work": "unix:///p/work.sock", "ok": "unix:///p/ok.sock"])
        #expect(
            steps == [.update(name: "colimabar-work", host: "unix:///p/work.sock"), .remove(name: "colimabar-gone")])
        #expect(ProfileContexts.arguments(steps[1]) == ["docker", "context", "rm", "-f", "colimabar-gone"])
    }

    @Test func otherContextsAreNeverTouched() {
        let existing = [
            Ctx(name: "colimabar-work", endpoint: "tcp://mine:2375", description: "my own context"),
            Ctx(name: "colimabar-old", endpoint: "tcp://mine:2375", description: ""),
            Ctx(name: "colimabar", endpoint: "unix:///s/docker.sock", description: "ColimaBar (auto-starts Colima)"),
            Ctx(name: "colima-work", endpoint: "unix:///c/docker.sock", description: "colima [profile=work]"),
        ]
        #expect(ProfileContexts.plan(existing: existing, wanted: ["work": "unix:///p/work.sock"]).isEmpty)
    }
}
