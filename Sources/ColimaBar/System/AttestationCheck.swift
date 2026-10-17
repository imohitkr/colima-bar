import Foundation
import os

/// Checks the build provenance attestation of the download with `gh`, with
/// the same flags as `scripts/install.sh`. The check proves that the release
/// workflow of this repository built the file from the tag on a GitHub-hosted
/// runner. If `gh` cannot run the check when the user confirms, the dialog
/// says so, and the update goes on with the digest check only. If `gh` could
/// run it then, a later failure to run it stops the update.
enum AttestationCheck {
    enum Outcome: Equatable, Sendable {
        case verified
        /// `gh` cannot run the check. The text says why.
        case skipped(String)
    }

    static let repo = "imohitkr/colima-bar"
    static let workflow = "imohitkr/colima-bar/.github/workflows/ci.yml"
    /// The first version of gh with all the flags below.
    static let minimumVersion = [2, 68, 0]

    /// The X.Y.Z version in the first line of `gh --version`
    /// ("gh version 2.68.1 (2025-03-06)"), or nil for another format.
    static func parseVersion(_ output: String) -> [Int]? {
        let first = output.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
        let words = first.split(separator: " ")
        guard words.count >= 3, words[0] == "gh", words[1] == "version" else { return nil }
        let v = words[2].hasPrefix("v") ? words[2].dropFirst() : words[2]
        let parts = v.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 3 else { return nil }
        let nums = parts.prefix(3).map { $0.prefix { $0.isASCII && $0.isNumber } }
        guard nums.allSatisfy({ !$0.isEmpty }), let a = Int(nums[0]), let b = Int(nums[1]), let c = Int(nums[2])
        else { return nil }
        return [a, b, c]
    }

    /// True if `version` is `minimumVersion` or later. Each part counts as a number.
    static func isSupported(_ version: [Int]) -> Bool {
        for (a, b) in zip(version, minimumVersion) where a != b { return a > b }
        return true
    }

    /// The arguments of `gh` for the zip of `tag`.
    static func arguments(zip: String, tag: String) -> [String] {
        [
            "gh", "attestation", "verify", zip, "--hostname", "github.com", "--repo", repo,
            "--signer-workflow", workflow, "--deny-self-hosted-runners", "--source-ref", "refs/tags/\(tag)",
        ]
    }

    /// Why the check cannot run, or nil if `gh` is ready. It runs `gh` twice
    /// (the version and the login), each with a short limit.
    static func skipReason() async -> String? {
        guard Shell.which("gh") != nil else { return "gh is not installed" }
        let v = await Shell.run(["gh", "--version"], timeout: 10, cancellable: true)
        guard v.ok, let version = parseVersion(v.out) else {
            return "the gh version cannot be read; gh 2.68 or later is needed"
        }
        guard isSupported(version) else {
            return "gh \(version.map(String.init).joined(separator: ".")) is too old; gh 2.68 or later is needed"
        }
        let auth = await Shell.run(
            ["gh", "auth", "status", "--hostname", "github.com"], timeout: 15, cancellable: true)
        return auth.ok ? nil : "gh is not logged in to github.com"
    }

    /// Words in the `gh` output that show a network problem, not a verdict
    /// on the file.
    private static let networkMarkers = [
        "dial tcp", "i/o timeout", "no such host", "tls handshake", "connection refused", "connection reset",
        "network is unreachable", "context deadline", "timeout", "rate limit", "http 5", "status 5",
        "error connecting",
    ]

    /// The error for a failed `gh attestation verify`. A kill by the time
    /// limit (SIGTERM or SIGKILL) and a network text are retryable
    /// (`attestationUnavailable`). Anything else is a failed check.
    static func failure(status: Int32, output: String) -> UpdateError {
        let text = output.lowercased()
        if status == SIGTERM || status == SIGKILL || status == -1 {
            return .attestationUnavailable("gh did not finish the check")
        }
        if networkMarkers.contains(where: { text.contains($0) }) {
            return .attestationUnavailable("gh could not reach GitHub")
        }
        return .attestationFailed
    }

    /// The default `gh` run, with stderr, that a cancel stops.
    static let runGh: @Sendable ([String]) async -> Shell.Result = { args in
        await Shell.run(args, timeout: 60, includeStderr: true, cancellable: true)
    }

    /// Runs the check.
    /// - `allowSkip` is true only if the confirmation dialog told the user
    ///   that the check would not run. Then a `gh` that cannot run gives
    ///   `.skipped`.
    /// - With `allowSkip` false, the dialog promised the check. If `gh` cannot
    ///   run it now, the update stops (`attestationUnavailable`): the user
    ///   did not agree to a check with the digest only.
    /// `probe` and `runGh` are parameters so tests need no `gh`.
    static func verify(
        zip: URL, tag: String, allowSkip: Bool,
        probe: @Sendable () async -> String? = { await skipReason() },
        runGh: @Sendable ([String]) async -> Shell.Result = AttestationCheck.runGh
    ) async throws -> Outcome {
        if let why = await probe() {
            if allowSkip { return .skipped(why) }
            throw UpdateError.attestationUnavailable(why)
        }
        let r = await runGh(arguments(zip: zip.path, tag: tag))
        guard r.ok else {
            log.error("gh attestation verify failed with status \(r.status): \(r.out.prefix(1000), privacy: .public)")
            throw failure(status: r.status, output: r.out)
        }
        return .verified
    }

    private static let log = Logger(category: "update")
}
