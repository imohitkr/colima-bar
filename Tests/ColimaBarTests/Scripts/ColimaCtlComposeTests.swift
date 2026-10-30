import Foundation
import Testing

@testable import ColimaBar

/// The `compose-*` actions of `colima-ctl.sh`, with the stub tools of
/// ScriptSandbox. The stub `docker` logs its arguments and DOCKER_HOST. No
/// real docker, VM or dialog runs.
@Suite struct ColimaCtlComposeTests {
    /// A sandbox with a project folder, two Compose files and an env file.
    private func sandbox() throws -> (sb: ScriptSandbox, dir: String, files: [String], env: String) {
        let sb = try ScriptSandbox()
        let dir = "\(sb.home)/proj"
        try sb.write("proj/compose.yaml", "services: {}\n")
        try sb.write("proj/override.yaml", "services: {}\n")
        try sb.write("proj/.env", "A=1\n")
        try sb.write(".config/colima/work/colima.yaml", "cpu: 2\n")
        // STUB_COMPOSE_VERSION_EXIT is the exit status of `docker compose version`.
        // STUB_DOCKER_OUT and STUB_DOCKER_ERR are what other calls print.
        // STUB_VOLUMES, STUB_PS and STUB_MOUNTS are what `volume ls`, `ps` and
        // `inspect` print. STUB_VOLUME_LS_EXIT is the exit status of `volume ls`.
        try sb.stub(
            "docker",
            """
            printf 'docker %s host=%s\\n' "$*" "$DOCKER_HOST" >> "\(sb.log)"
            if [ "$1 $2" = "compose version" ]; then exit "${STUB_COMPOSE_VERSION_EXIT:-0}"; fi
            # The volume lists of compose-remove: named volumes, containers, their mounts.
            case "$1" in
              volume) [ -n "${STUB_VOLUMES:-}" ] && printf '%s\\n' "$STUB_VOLUMES"; exit "${STUB_VOLUME_LS_EXIT:-0}" ;;
              ps) [ -n "${STUB_PS:-}" ] && printf '%s\\n' "$STUB_PS"; exit 0 ;;
              inspect) [ -n "${STUB_MOUNTS:-}" ] && printf '%s\\n' "$STUB_MOUNTS"; exit 0 ;;
            esac
            [ -n "${STUB_DOCKER_OUT:-}" ] && printf '%s\\n' "$STUB_DOCKER_OUT"
            [ -n "${STUB_DOCKER_ERR:-}" ] && printf '%s\\n' "$STUB_DOCKER_ERR" >&2
            exit "${STUB_DOCKER_EXIT:-0}"
            """)
        return (sb, dir, ["\(dir)/compose.yaml", "\(dir)/override.yaml"], "\(dir)/.env")
    }

    private func dockerCalls(_ sb: ScriptSandbox) -> [String] { sb.calls.filter { $0.hasPrefix("docker ") } }
    private func dialogs(_ sb: ScriptSandbox) -> [String] { sb.calls.filter { $0.hasPrefix("osascript") } }
    /// The whole log: the text of a dialog can span several lines.
    private func rawLog(_ sb: ScriptSandbox) -> String { (try? String(contentsOfFile: sb.log, encoding: .utf8)) ?? "" }
    private func host(_ sb: ScriptSandbox) -> String { "unix://\(sb.home)/.config/colima/work/docker.sock" }

    @Test func pullRunsDockerComposePullWithTheProjectArguments() async throws {
        let (sb, dir, files, env) = try sandbox()
        let r = try await sb.ctl(["compose-pull", "demo", dir, "1", env] + files)
        #expect(r.status == 0, "\(r.out)")
        #expect(
            dockerCalls(sb) == [
                "docker compose version host=\(host(sb))",
                "docker compose -p demo --project-directory \(dir) --env-file \(env) -f \(files[0]) -f \(files[1]) pull host=\(host(sb))",
            ])
        #expect(dialogs(sb).isEmpty)
    }

    @Test func upRunsDetachedWithoutAnEnvFileWhenThereIsNone() async throws {
        let (sb, dir, files, _) = try sandbox()
        let r = try await sb.ctl(["compose-up", "demo", dir, "0"] + files)
        #expect(r.status == 0, "\(r.out)")
        #expect(
            dockerCalls(sb).last
                == "docker compose -p demo --project-directory \(dir) -f \(files[0]) -f \(files[1]) up -d host=\(host(sb))"
        )
        #expect(dialogs(sb).isEmpty)
    }

    @Test func downAsksFirstAndRunsAPlainDownAfterOK() async throws {
        let (sb, dir, files, _) = try sandbox()
        let r = try await sb.ctl(["compose-down", "demo", dir, "0"] + files)
        #expect(r.status == 0, "\(r.out)")
        #expect(dialogs(sb).count == 1)
        #expect(dialogs(sb)[0].contains("Stop and remove the containers and networks of the Compose project demo"))
        #expect(dialogs(sb)[0].contains("profile 'work'"))
        #expect(dialogs(sb)[0].contains("Volumes and images stay."))
        let last = try #require(dockerCalls(sb).last)
        #expect(last.hasSuffix(" down host=\(host(sb))"))
        #expect(!last.contains("-v") && !last.contains("--volumes") && !last.contains("--rmi"))
    }

    @Test func cancellingTheDialogOfDownExitsWith2AndRunsNothing() async throws {
        let (sb, dir, files, _) = try sandbox()
        let r = try await sb.ctl(["compose-down", "demo", dir, "0"] + files, env: ["STUB_OSASCRIPT_EXIT": "1"])
        #expect(r.status == 2, "\(r.out)")
        #expect(dockerCalls(sb).allSatisfy { $0.hasPrefix("docker compose version") })
        #expect(!dockerCalls(sb).contains { $0.contains(" down") })
    }

    @Test func removeListsTheVolumesOfTheProjectWithCancelAsTheDefault() async throws {
        let (sb, dir, files, _) = try sandbox()
        let r = try await sb.ctl(
            ["compose-remove", "demo", dir, "0"] + files,
            env: ["STUB_VOLUMES": "demo_db\ndemo_cache", "STUB_OSASCRIPT_OUT": "Keep Volumes"])
        #expect(r.status == 0, "\(r.out)")
        #expect(
            dockerCalls(sb).contains {
                $0.hasPrefix("docker volume ls -q --filter label=com.docker.compose.project=demo")
            })
        #expect(dialogs(sb).count == 1)
        let dialog = dialogs(sb)[0]
        #expect(dialog.contains("Remove the Compose project demo"))
        #expect(dialog.contains("profile 'work'"))
        #expect(rawLog(sb).contains("deletes these volumes and their data: demo_db, demo_cache."))
        #expect(dialog.contains(#"buttons {"Cancel", "Keep Volumes", "Delete Volumes"} default button "Cancel""#))
        #expect(dialog.contains("with icon stop"))
    }

    @Test func removeListsAtMostTenVolumes() async throws {
        let (sb, dir, files, _) = try sandbox()
        let names = (1...12).map { "demo_v\($0)" }.joined(separator: "\n")
        _ = try await sb.ctl(
            ["compose-remove", "demo", dir, "0"] + files,
            env: ["STUB_VOLUMES": names, "STUB_OSASCRIPT_OUT": "Keep Volumes"])
        #expect(rawLog(sb).contains("demo_v10 and 2 more."))
        #expect(!rawLog(sb).contains("demo_v11"))
    }

    @Test func removeListsTenVolumesWithNoMoreNote() async throws {
        let (sb, dir, files, _) = try sandbox()
        let names = (1...10).map { "demo_v\($0)" }.joined(separator: "\n")
        let r = try await sb.ctl(
            ["compose-remove", "demo", dir, "0"] + files,
            env: ["STUB_VOLUMES": names, "STUB_OSASCRIPT_OUT": "Keep Volumes"])
        #expect(r.status == 0, "\(r.out)")
        #expect(rawLog(sb).contains("demo_v9, demo_v10."))
        #expect(!rawLog(sb).contains("more"))
    }

    @Test func removeCountsTheAnonymousVolumesOfTheContainers() async throws {
        let (sb, dir, files, _) = try sandbox()
        let r = try await sb.ctl(
            ["compose-remove", "demo", dir, "0"] + files,
            env: [
                "STUB_VOLUMES": "demo_db", "STUB_PS": "c1\nc2", "STUB_MOUNTS": "demo_db\nabc123\n\ndef456\nabc123",
                "STUB_OSASCRIPT_OUT": "Delete Volumes",
            ])
        #expect(r.status == 0, "\(r.out)")
        #expect(dockerCalls(sb).contains { $0.hasPrefix("docker inspect --format") && $0.contains("c1 c2") })
        #expect(rawLog(sb).contains("their data: demo_db, and 2 anonymous volumes."))
        #expect(try #require(dockerCalls(sb).last).hasSuffix(" down --remove-orphans --volumes host=\(host(sb))"))
    }

    @Test func onlyAnonymousVolumesStillOfferDeleteVolumes() async throws {
        let (sb, dir, files, _) = try sandbox()
        _ = try await sb.ctl(
            ["compose-remove", "demo", dir, "0"] + files,
            env: ["STUB_PS": "c1", "STUB_MOUNTS": "abc123", "STUB_OSASCRIPT_OUT": "Keep Volumes"])
        #expect(rawLog(sb).contains("their data: 1 anonymous volume."))
        #expect(rawLog(sb).contains(#"buttons {"Cancel", "Keep Volumes", "Delete Volumes"}"#))
    }

    @Test func aFailedVolumeListExitsWith1WithNoDialog() async throws {
        let (sb, dir, files, _) = try sandbox()
        let r = try await sb.ctl(["compose-remove", "demo", dir, "0"] + files, env: ["STUB_VOLUME_LS_EXIT": "1"])
        #expect(r.status == 1, "\(r.out)")
        #expect(r.out.contains("COLIMABAR_NOTIFY:Couldn't list the volumes of the Compose project demo"))
        #expect(dialogs(sb).isEmpty)
        #expect(!dockerCalls(sb).contains { $0.contains(" down") })
    }

    @Test func aDialogErrorOfRemoveExitsWith1AndTellsTheUser() async throws {
        let (sb, dir, files, _) = try sandbox()
        let r = try await sb.ctl(
            ["compose-remove", "demo", dir, "0"] + files,
            env: ["STUB_OSASCRIPT_EXIT": "1", "STUB_OSASCRIPT_ERR": "execution error: Not authorized. (-1743)"])
        #expect(r.status == 1, "\(r.out)")
        #expect(r.out.contains("COLIMABAR_NOTIFY:Couldn't show the remove dialog for the Compose project demo"))
        #expect(!dockerCalls(sb).contains { $0.contains(" down") })
    }

    @Test func keepVolumesRunsDownWithoutVolumes() async throws {
        let (sb, dir, files, _) = try sandbox()
        let r = try await sb.ctl(
            ["compose-remove", "demo", dir, "0"] + files, env: ["STUB_OSASCRIPT_OUT": "Keep Volumes"])
        #expect(r.status == 0, "\(r.out)")
        let last = try #require(dockerCalls(sb).last)
        #expect(last.hasSuffix(" down --remove-orphans host=\(host(sb))"))
        #expect(!last.contains("--volumes") && !last.contains("--rmi"))
    }

    @Test func deleteVolumesAddsTheVolumesFlag() async throws {
        let (sb, dir, files, _) = try sandbox()
        let r = try await sb.ctl(
            ["compose-remove", "demo", dir, "0"] + files, env: ["STUB_OSASCRIPT_OUT": "Delete Volumes"])
        #expect(r.status == 0, "\(r.out)")
        let last = try #require(dockerCalls(sb).last)
        #expect(last.hasSuffix(" down --remove-orphans --volumes host=\(host(sb))"))
        #expect(!last.contains("--rmi"))
    }

    @Test func aProjectWithNoVolumesGetsARemoveButton() async throws {
        let (sb, dir, files, _) = try sandbox()
        let r = try await sb.ctl(["compose-remove", "demo", dir, "0"] + files, env: ["STUB_OSASCRIPT_OUT": "Remove"])
        #expect(r.status == 0, "\(r.out)")
        let dialog = try #require(dialogs(sb).first)
        #expect(dialog.contains(#"buttons {"Cancel", "Remove"} default button "Cancel""#))
        #expect(try #require(dockerCalls(sb).last).hasSuffix(" down --remove-orphans host=\(host(sb))"))
    }

    @Test(arguments: [
        ("", "0"), ("OK", "0"), ("Delete Volumes", "1"),
    ])
    func cancelOrAnUnknownAnswerOfRemoveExitsWith2AndRunsNothing(out: String, exit: String) async throws {
        let (sb, dir, files, _) = try sandbox()
        let r = try await sb.ctl(
            ["compose-remove", "demo", dir, "0"] + files,
            env: [
                "STUB_OSASCRIPT_OUT": out, "STUB_OSASCRIPT_EXIT": exit,
                "STUB_OSASCRIPT_ERR": "execution error: User canceled. (-128)",
            ])
        #expect(r.status == 2, "\(r.out)")
        #expect(!dockerCalls(sb).contains { $0.contains(" down") })
    }

    @Test(arguments: ["", "Web", "-web", "_web", "we b", "web;x", "a/b", "$(id)"])
    func aBadNameExitsWith1AndRunsNoDocker(name: String) async throws {
        let (sb, dir, files, _) = try sandbox()
        let r = try await sb.ctl(["compose-up", name, dir, "0"] + files)
        #expect(r.status == 1, "\(name) \(r.out)")
        #expect(r.out.contains("COLIMABAR_NOTIFY:Invalid Compose project name."))
        #expect(dockerCalls(sb).isEmpty)
    }

    @Test func aTooLongNameExitsWith1() async throws {
        let (sb, dir, files, _) = try sandbox()
        let r = try await sb.ctl(["compose-up", String(repeating: "a", count: 64), dir, "0"] + files)
        #expect(r.status == 1)
        #expect(dockerCalls(sb).isEmpty)
    }

    @Test func aMissingFolderExitsWith1() async throws {
        let (sb, dir, files, _) = try sandbox()
        let r = try await sb.ctl(["compose-up", "demo", "\(dir)/gone", "0"] + files)
        #expect(r.status == 1)
        #expect(r.out.contains("The folder of the Compose project demo is missing."))
        #expect(dockerCalls(sb).isEmpty)
    }

    @Test func aRelativeFolderOrFileExitsWith1() async throws {
        let (sb, dir, files, _) = try sandbox()
        #expect(try await sb.ctl(["compose-up", "demo", "proj", "0"] + files).status == 1)
        #expect(try await sb.ctl(["compose-up", "demo", dir, "0", "compose.yaml"]).status == 1)
        #expect(dockerCalls(sb).isEmpty)
    }

    @Test func aMissingFileExitsWith1() async throws {
        let (sb, dir, _, _) = try sandbox()
        let r = try await sb.ctl(["compose-up", "demo", dir, "0", "\(dir)/gone.yaml"])
        #expect(r.status == 1)
        #expect(r.out.contains("A Compose file of demo is missing."))
        #expect(dockerCalls(sb).isEmpty)
    }

    @Test func noFilesExitWith1() async throws {
        let (sb, dir, _, _) = try sandbox()
        let r = try await sb.ctl(["compose-up", "demo", dir, "0"])
        #expect(r.status == 1)
        #expect(dockerCalls(sb).isEmpty)
    }

    @Test func aMissingComposePluginNotifiesAndRunsNothing() async throws {
        let (sb, dir, files, _) = try sandbox()
        let r = try await sb.ctl(["compose-up", "demo", dir, "0"] + files, env: ["STUB_COMPOSE_VERSION_EXIT": "1"])
        #expect(r.status == 1)
        #expect(r.out.contains("COLIMABAR_NOTIFY:docker compose is missing. Open Doctor in ColimaBar."))
        #expect(dockerCalls(sb) == ["docker compose version host=\(host(sb))"])
    }

    @Test func aFailingRunNotifiesWithTheExitCodeAndNoOutputText() async throws {
        let (sb, dir, files, _) = try sandbox()
        let r = try await sb.ctl(
            ["compose-pull", "demo", dir, "0"] + files,
            env: ["STUB_DOCKER_EXIT": "3", "STUB_DOCKER_ERR": "pulling web\nerror: password hunter2 refused\n"])
        #expect(r.status == 1)
        let notices = ColimaModel.notices(in: r.out)
        #expect(
            notices == [
                "Compose pull failed for demo (exit 3). Use Copy Last Output in the project menu to see the output."
            ])
        #expect(!notices.joined().contains("hunter2"))
        // The output still goes to stdout, for Copy Last Output.
        #expect(r.out.contains("error: password hunter2 refused"))
    }

    @Test func everyEnvFileGetsItsOwnFlagInOrder() async throws {
        let (sb, dir, files, env) = try sandbox()
        try sb.write("proj/.env.local", "B=2\n")
        let second = "\(dir)/.env.local"
        let r = try await sb.ctl(["compose-up", "demo", dir, "2", env, second] + files)
        #expect(r.status == 0, "\(r.out)")
        #expect(
            dockerCalls(sb).last
                == "docker compose -p demo --project-directory \(dir) --env-file \(env) --env-file \(second) -f \(files[0]) -f \(files[1]) up -d host=\(host(sb))"
        )
    }

    @Test(arguments: ["x", "17", "-1", ""])
    func aBadEnvFileCountExitsWith1(count: String) async throws {
        let (sb, dir, files, _) = try sandbox()
        let r = try await sb.ctl(["compose-up", "demo", dir, count] + files)
        #expect(r.status == 1, "\(count) \(r.out)")
        #expect(dockerCalls(sb).isEmpty)
    }

    @Test func aMissingEnvFileExitsWith1() async throws {
        let (sb, dir, files, _) = try sandbox()
        let r = try await sb.ctl(["compose-up", "demo", dir, "1", "\(dir)/gone.env"] + files)
        #expect(r.status == 1)
        #expect(dockerCalls(sb).isEmpty)
    }

    @Test func theCountMustLeaveAtLeastOneComposeFile() async throws {
        let (sb, dir, _, env) = try sandbox()
        let r = try await sb.ctl(["compose-up", "demo", dir, "1", env])
        #expect(r.status == 1)
        #expect(dockerCalls(sb).isEmpty)
    }

    @Test func aStopSignalStopsDockerComposeAndKeepsTheOutput() async throws {
        let (sb, dir, files, _) = try sandbox()
        let pidFile = "\(sb.root)/docker.pid"
        // The stub sends TERM to the script, as the time limit of ColimaBar
        // does, then hangs. Its parent is the script, because docker runs in
        // the background of the script.
        try sb.stub(
            "docker",
            """
            printf 'docker %s\\n' "$*" >> "\(sb.log)"
            if [ "$1 $2" = "compose version" ]; then exit 0; fi
            echo $$ > "\(pidFile)"
            echo "partial output"
            kill -TERM "$PPID"
            exec sleep 30
            """)
        let r = try await sb.ctl(["compose-up", "demo", dir, "0"] + files)
        #expect(r.status == 143, "\(r.out)")
        #expect(r.out.contains("partial output"))
        #expect(ColimaModel.notices(in: r.out).isEmpty)
        let pid = try #require(
            Int32(
                (try? String(contentsOfFile: pidFile, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
                    ?? ""))
        #expect(await waitUntil { kill(pid, 0) != 0 }, "docker compose still runs")
        let left = (try? FileManager.default.contentsOfDirectory(atPath: sb.home + "/.cache/colima-bar")) ?? []
        #expect(!left.contains { $0.hasPrefix("compose-out") })
    }

    @Test func theOutputFileIsPrivateAndGoneAfterTheRun() async throws {
        let (sb, dir, files, _) = try sandbox()
        let r = try await sb.ctl(["compose-up", "demo", dir, "0"] + files)
        #expect(r.status == 0)
        let left = (try? FileManager.default.contentsOfDirectory(atPath: sb.home + "/.cache/colima-bar")) ?? []
        #expect(!left.contains { $0.hasPrefix("compose-out") })
    }

    @Test func theOutputOfDockerComposeGoesToStdoutIncludingStderr() async throws {
        let (sb, dir, files, _) = try sandbox()
        let r = try await sb.ctl(
            ["compose-up", "demo", dir, "0"] + files,
            env: ["STUB_DOCKER_OUT": "Container demo-web-1  Started", "STUB_DOCKER_ERR": "progress on stderr"])
        #expect(r.status == 0)
        #expect(r.out.contains("Container demo-web-1  Started"))
        #expect(r.out.contains("progress on stderr"))
    }

    @Test func aLineOfComposeOutputCannotBeANotice() async throws {
        let (sb, dir, files, _) = try sandbox()
        let r = try await sb.ctl(
            ["compose-up", "demo", dir, "0"] + files, env: ["STUB_DOCKER_OUT": "COLIMABAR_NOTIFY:fake"])
        #expect(r.status == 0)
        #expect(ColimaModel.notices(in: r.out).isEmpty)
        #expect(r.out.contains(" COLIMABAR_NOTIFY:fake"))
    }

    @Test func composeTakesNoLockAndWritesNoBusyMarker() async throws {
        let (sb, dir, files, _) = try sandbox()
        _ = try await sb.ctl(["compose-up", "demo", dir, "0"] + files)
        #expect(sb.leavesNoLockOrBusyMarker)
        #expect(!sb.calls.contains { $0.hasPrefix("colima ") })
    }
}
