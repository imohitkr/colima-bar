import Foundation
import Testing

@testable import ColimaBar

/// The `ctr-debug` and `ctr-shell` actions of `colima-ctl.sh`, with the stub
/// `docker` of ScriptSandbox. No real docker or VM runs.
@Suite struct ColimaCtlDebugShellTests {
    private let id = String(repeating: "ab12", count: 16)
    private let sidecar = "colimabar-debug-ab12ab12ab12"

    /// The stub logs its arguments and DOCKER_HOST. STUB_INSPECT is the output
    /// of `docker inspect` (empty: the container does not exist). STUB_PROBE_ERR is the error of the shell probe
    /// (`exec -- NAME sh -c :`), which then fails.
    private func sandbox() throws -> ScriptSandbox {
        let sb = try ScriptSandbox()
        try sb.write(".config/colima/work/colima.yaml", "cpu: 2\n")
        try sb.stub(
            "docker",
            """
            printf 'docker %s host=%s\\n' "$*" "$DOCKER_HOST" >> "\(sb.log)"
            if [ "$1" = inspect ]; then
              [ -n "${STUB_INSPECT:-}" ] || exit 1
              printf '%s\\n' "$STUB_INSPECT"; exit 0
            fi
            if [ "$1" = exec ] && [ "$4" = sh ] && [ "$6" = : ] && [ -n "${STUB_PROBE_ERR:-}" ]; then
              printf '%s\\n' "$STUB_PROBE_ERR" >&2; exit 126
            fi
            if [ "$1" = exec ] && [ "$4" = sh ] && [ "$6" = : ] && [ -n "${STUB_PROBE_OUT:-}" ]; then
              printf '%s\\n' "$STUB_PROBE_OUT"; exit 127
            fi
            exit 0
            """)
        return sb
    }

    private func dockerCalls(_ sb: ScriptSandbox) -> [String] { sb.calls.filter { $0.hasPrefix("docker ") } }
    private func host(_ sb: ScriptSandbox) -> String { "unix://\(sb.home)/.config/colima/work/docker.sock" }

    @Test func debugRunsTheSidecarWithTheExactArguments() async throws {
        let sb = try sandbox()
        let r = try await sb.ctl(["ctr-debug", id, "busybox:latest"])
        #expect(r.status == 0, "\(r.out)")
        #expect(r.out.contains("Debug shell for container ab12ab12ab12, image busybox:latest."))
        #expect(r.out.contains("Its files are in /proc/1/root."))
        #expect(
            dockerCalls(sb).last
                == "docker run --rm -it --name \(sidecar) --pid container:\(id) --network container:\(id) --cap-add SYS_PTRACE busybox:latest host=\(host(sb))"
        )
    }

    @Test func debugUsesTheProfileSocketNotTheProxy() async throws {
        let sb = try sandbox()
        _ = try await sb.ctl(["ctr-debug", id, "busybox"])
        #expect(dockerCalls(sb).allSatisfy { $0.hasSuffix("host=\(host(sb))") })
        #expect(!dockerCalls(sb).contains { $0.contains("colima-bar/docker.sock") })
    }

    @Test(arguments: [
        "", "web", String(repeating: "ab12", count: 15) + "ab1", String(repeating: "AB12", count: 16),
        String(repeating: "ab12", count: 16) + "a", "-" + String(repeating: "a", count: 63),
    ])
    func aBadIDExitsWith1AndRunsNoDocker(value: String) async throws {
        let sb = try sandbox()
        let r = try await sb.ctl(["ctr-debug", value, "busybox"])
        #expect(r.status == 1, "\(r.out)")
        #expect(r.out.contains("the container ID is not valid"))
        #expect(dockerCalls(sb).isEmpty)
    }

    @Test(arguments: ["", "-v", "--privileged", "a b", "a;b", "$(id)", "a'b", "a\"b", ".a", "/a", "Busybox", "a`b"])
    func aBadImageExitsWith1AndRunsNoDocker(value: String) async throws {
        let sb = try sandbox()
        let r = try await sb.ctl(["ctr-debug", id, value])
        #expect(r.status == 1, "\(r.out)")
        #expect(r.out.contains("the image name is not valid"))
        #expect(dockerCalls(sb).isEmpty)
    }

    @Test func aTooLongImageExitsWith1() async throws {
        let sb = try sandbox()
        let r = try await sb.ctl(["ctr-debug", id, String(repeating: "a", count: 256)])
        #expect(r.status == 1, "\(r.out)")
        #expect(dockerCalls(sb).isEmpty)
    }

    @Test func aRunningSidecarGetsASecondShell() async throws {
        let sb = try sandbox()
        let r = try await sb.ctl(["ctr-debug", id, "busybox"], env: ["STUB_INSPECT": "true"])
        #expect(r.status == 0, "\(r.out)")
        #expect(dockerCalls(sb).last == "docker exec -it -- \(sidecar) sh host=\(host(sb))")
        #expect(!dockerCalls(sb).contains { $0.hasPrefix("docker run") })
        #expect(!r.out.contains("COLIMABAR_NOTIFY"))
        #expect(!r.out.contains("Removed"))
    }

    @Test func aStoppedSidecarIsRemovedBeforeTheNewRun() async throws {
        let sb = try sandbox()
        let r = try await sb.ctl(["ctr-debug", id, "busybox"], env: ["STUB_INSPECT": "false"])
        #expect(r.status == 0, "\(r.out)")
        #expect(r.out.contains("Removed an old debug container."))
        let calls = dockerCalls(sb)
        #expect(calls.contains("docker inspect --type container -f {{.State.Running}} -- \(sidecar) host=\(host(sb))"))
        let rm = calls.firstIndex { $0.hasPrefix("docker rm -- \(sidecar)") }
        let run = calls.firstIndex { $0.hasPrefix("docker run") }
        #expect(rm != nil && run != nil && rm! < run!)
    }

    @Test func noSidecarMeansNoRemoval() async throws {
        let sb = try sandbox()
        let r = try await sb.ctl(["ctr-debug", id, "busybox"])
        #expect(!r.out.contains("Removed"))
        #expect(!dockerCalls(sb).contains { $0.hasPrefix("docker rm") })
    }

    @Test(arguments: [
        "nicolaka/netshoot:latest", "localhost:5000/a/b", "ghcr.io/a/b@sha256:" + String(repeating: "a", count: 64),
    ])
    func aNormalImageNameRuns(value: String) async throws {
        let sb = try sandbox()
        let r = try await sb.ctl(["ctr-debug", id, value])
        #expect(r.status == 0, "\(r.out)")
        #expect(dockerCalls(sb).last?.contains("--cap-add SYS_PTRACE \(value) host=") == true)
    }

    @Test func shellPrintsTheHintWhenTheContainerHasNoShell() async throws {
        let sb = try sandbox()
        let r = try await sb.ctl(
            ["ctr-shell", "web"],
            env: ["STUB_PROBE_ERR": "OCI runtime exec failed: exec: \"sh\": executable file not found in $PATH"])
        #expect(r.status == 1, "\(r.out)")
        #expect(r.out.contains("Container web has no shell."))
        #expect(r.out.contains("choose Debug shell."))
        #expect(!dockerCalls(sb).contains { $0.contains("exec -it") })
    }

    /// Docker 29 prints the OCI error on stdout, not on stderr.
    @Test func shellPrintsTheHintWhenDockerPrintsTheErrorOnStdout() async throws {
        let sb = try sandbox()
        let r = try await sb.ctl(
            ["ctr-shell", "web"],
            env: [
                "STUB_PROBE_OUT":
                    "OCI runtime exec failed: exec failed: unable to start container process: exec: \"sh\": executable file not found in $PATH"
            ])
        #expect(r.status == 1, "\(r.out)")
        #expect(r.out.contains("Container web has no shell."))
        #expect(!dockerCalls(sb).contains { $0.contains("exec -it") })
    }

    @Test func shellOpensTheShellWhenTheProbeWorks() async throws {
        let sb = try sandbox()
        let r = try await sb.ctl(["ctr-shell", "web"])
        #expect(r.status == 0, "\(r.out)")
        #expect(dockerCalls(sb).first == "docker exec -- web sh -c : host=\(host(sb))")
        #expect(dockerCalls(sb).last?.hasPrefix("docker exec -it -- web sh -c ") == true)
    }

    @Test func shellFallsThroughOnAnotherProbeError() async throws {
        let sb = try sandbox()
        let r = try await sb.ctl(["ctr-shell", "web"], env: ["STUB_PROBE_ERR": "container is not running"])
        #expect(!r.out.contains("has no shell"))
        #expect(dockerCalls(sb).last?.hasPrefix("docker exec -it -- web sh -c ") == true)
    }
}
