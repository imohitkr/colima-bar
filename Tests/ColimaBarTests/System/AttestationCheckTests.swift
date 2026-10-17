import Foundation
import Testing

@testable import ColimaBar

@Suite struct AttestationCheckTests {
    @Test func readsTheGhVersionFromTheFirstLine() {
        #expect(
            AttestationCheck.parseVersion(
                "gh version 2.68.1 (2025-03-06)\nhttps://github.com/cli/cli/releases/tag/v2.68.1\n") == [2, 68, 1])
        #expect(AttestationCheck.parseVersion("gh version v2.100.0 (2026-01-01)") == [2, 100, 0])
        #expect(AttestationCheck.parseVersion("gh version 2.70.0-rc1 (2026-01-01)") == [2, 70, 0])
    }

    @Test func rejectsOtherFormats() {
        for bad in [
            "", "gh 2.68.1", "version 2.68.1", "gh version", "gh version 2.68", "gh version x.y.z",
            "git version 2.68.1",
        ] {
            #expect(AttestationCheck.parseVersion(bad) == nil, "\(bad)")
        }
    }

    @Test func needsGh268OrLater() {
        #expect(AttestationCheck.isSupported([2, 68, 0]))
        #expect(AttestationCheck.isSupported([2, 100, 0]))  // each part is a number
        #expect(AttestationCheck.isSupported([3, 0, 0]))
        #expect(!AttestationCheck.isSupported([2, 67, 9]))
        #expect(!AttestationCheck.isSupported([1, 99, 0]))
    }

    @Test func usesTheFlagsOfTheInstaller() throws {
        let script = try String(contentsOfFile: Self.repoFile("scripts/install.sh"), encoding: .utf8)
        let args = AttestationCheck.arguments(zip: "/tmp/ColimaBar.zip", tag: "v0.9.1")
        #expect(args.prefix(4) == ["gh", "attestation", "verify", "/tmp/ColimaBar.zip"])
        // Each flag with its value in the installer's verify list.
        for flag in ["--hostname", "--repo", "--signer-workflow", "--source-ref"] {
            let i = try #require(args.firstIndex(of: flag))
            #expect(script.contains("\(flag) "), "\(flag)")
            #expect(i + 1 < args.count)
        }
        #expect(args.contains("--deny-self-hosted-runners"))
        #expect(script.contains("--deny-self-hosted-runners"))
        #expect(args[args.firstIndex(of: "--hostname")! + 1] == "github.com")
        #expect(script.contains("--hostname github.com"))
        #expect(args[args.firstIndex(of: "--repo")! + 1] == "imohitkr/colima-bar")
        #expect(script.contains("local repo=\"imohitkr/colima-bar\""))
        #expect(args[args.firstIndex(of: "--signer-workflow")! + 1] == "imohitkr/colima-bar/.github/workflows/ci.yml")
        #expect(script.contains("local workflow=\"$repo/.github/workflows/ci.yml\""))
        #expect(args[args.firstIndex(of: "--source-ref")! + 1] == "refs/tags/v0.9.1")
        #expect(script.contains("--source-ref \"refs/tags/$version\""))
    }

    @Test func theMinimumVersionIsTheOneOfTheInstaller() throws {
        let script = try String(contentsOfFile: Self.repoFile("scripts/install.sh"), encoding: .utf8)
        #expect(
            script.contains(
                "version_at_least \"$ghv\" \(AttestationCheck.minimumVersion.map(String.init).joined(separator: "."))"))
    }

    private static func repoFile(_ path: String, file: String = #filePath) -> String {
        var url = URL(fileURLWithPath: file)
        while url.path != "/", !FileManager.default.fileExists(atPath: url.appendingPathComponent("Package.swift").path)
        {
            url.deleteLastPathComponent()
        }
        return url.appendingPathComponent(path).path
    }

    // MARK: fail closed after a promised check

    private let zip = URL(fileURLWithPath: "/tmp/ColimaBar.zip")

    private func ok(_ out: String = "") -> @Sendable ([String]) async -> Shell.Result {
        { _ in Shell.Result(status: 0, out: out) }
    }

    @Test func aCheckThatGhCannotRunStopsTheUpdateWhenTheDialogPromisedIt() async {
        await #expect(throws: UpdateError.attestationUnavailable("gh is not logged in to github.com")) {
            try await AttestationCheck.verify(
                zip: zip, tag: "v0.9.1", allowSkip: false, probe: { "gh is not logged in to github.com" },
                runGh: { _ in
                    Issue.record("gh must not run")
                    return Shell.Result(status: 0, out: "")
                })
        }
    }

    @Test func aCheckThatGhCannotRunIsSkippedOnlyWhenTheDialogSaidSo() async throws {
        let outcome = try await AttestationCheck.verify(
            zip: zip, tag: "v0.9.1", allowSkip: true, probe: { "gh is not installed" }, runGh: ok())
        #expect(outcome == .skipped("gh is not installed"))
    }

    @Test func aReadyGhRunsTheCheckEvenWhenSkipWasAllowed() async throws {
        let outcome = try await AttestationCheck.verify(
            zip: zip, tag: "v0.9.1", allowSkip: true, probe: { nil }, runGh: ok())
        #expect(outcome == .verified)
    }

    @Test func aPassingCheckIsVerified() async throws {
        let outcome = try await AttestationCheck.verify(
            zip: zip, tag: "v0.9.1", allowSkip: false, probe: { nil }, runGh: ok())
        #expect(outcome == .verified)
    }

    @Test func aFailedCheckStopsTheUpdateInEveryMode() async {
        for allow in [true, false] {
            await #expect(throws: UpdateError.attestationFailed) {
                try await AttestationCheck.verify(
                    zip: zip, tag: "v0.9.1", allowSkip: allow, probe: { nil },
                    runGh: { _ in Shell.Result(status: 1, out: "verification failed: no matching attestation") })
            }
        }
    }

    @Test func aTimeOutOrANetworkErrorOfGhIsRetryableNotAVerdict() {
        for status in [SIGTERM, SIGKILL, -1] {
            guard case .attestationUnavailable = AttestationCheck.failure(status: status, output: "") else {
                Issue.record("status \(status)")
                continue
            }
        }
        for text in [
            "Get \"https://api.github.com\": dial tcp: lookup api.github.com: no such host",
            "net/http: TLS handshake timeout", "HTTP 503: service unavailable (status 503)",
        ] {
            guard case .attestationUnavailable = AttestationCheck.failure(status: 1, output: text) else {
                Issue.record("\(text)")
                continue
            }
        }
        #expect(
            AttestationCheck.failure(status: 1, output: "Error: verifying with issuer sigstore.dev")
                == .attestationFailed)
        #expect(!AttestationCheck.failure(status: SIGTERM, output: "").usesReleasePageAfter)
        #expect(AttestationCheck.failure(status: 1, output: "x").usesReleasePageAfter)
    }
}
