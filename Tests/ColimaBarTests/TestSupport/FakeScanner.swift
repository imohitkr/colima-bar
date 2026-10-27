import Foundation

@testable import ColimaBar

/// A fake scanner runner. It records each call, notes whether the input file
/// existed at the time, and writes a report where the arguments say. No test
/// reaches a real scanner.
/// `@unchecked Sendable`: `lock` guards the recorded values.
final class FakeScanner: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [(args: [String], env: [String: String], timeout: TimeInterval)] = []
    private var inputs: [Bool] = []
    private var versions: [[String]] = []
    private var versionEnvs: [[String: String]] = []
    /// The text that the fake writes as the report. Nil writes none.
    var report: String? = #"{"Results":[]}"#
    var status: Int32 = 0
    var log = ""
    /// The fake says that ColimaBar stopped it at the time limit.
    var timedOut = false
    /// If set, the fake waits until the task is cancelled, or `release()`, before it answers.
    var hold = false
    private var released = false

    /// Ends the wait of `hold`. The fake then answers as if it had not waited.
    func release() { lock.withLock { released = true } }

    var calls: [[String]] { lock.withLock { recorded.map(\.args) } }
    var environments: [[String: String]] { lock.withLock { recorded.map(\.env) } }
    var timeouts: [TimeInterval] { lock.withLock { recorded.map(\.timeout) } }
    /// For each call: the input file existed while the scanner ran.
    var inputExisted: [Bool] { lock.withLock { inputs } }

    /// The version probes. A version probe is not a scan: `calls` leaves it out.
    var versionCalls: [[String]] { lock.withLock { versions } }
    var versionEnvironments: [[String: String]] { lock.withLock { versionEnvs } }
    /// The version that the fake reports.
    var version = "1.2.3"

    var run: ImageScanRunner.Run {
        { [self] args, env, timeout in
            if ImageScanner.allCases.contains(where: { $0.versionArguments == args }) {
                lock.withLock {
                    versions.append(args)
                    versionEnvs.append(env)
                }
                return Shell.Result(status: 0, out: #"{"Version":"\#(version)","version":"\#(version)"}"#)
            }
            let input =
                Self.path(after: ["--input"], in: args)
                ?? args.first { $0.contains(":/") }?.split(separator: ":", maxSplits: 1).last.map(String.init)
            lock.withLock {
                recorded.append((args, env, timeout))
                inputs.append(input.map { FileManager.default.fileExists(atPath: $0) } ?? false)
            }
            if hold {
                while !Task.isCancelled, !lock.withLock({ released }) {
                    try? await Task.sleep(for: .milliseconds(10))
                }
                if Task.isCancelled { return Shell.Result(status: 15, out: "") }
            }
            if let report, let out = Self.path(after: ["--output", "--file"], in: args) {
                try? Data(report.utf8).write(to: URL(fileURLWithPath: out))
            }
            return Shell.Result(status: status, out: log, timedOut: timedOut)
        }
    }

    private static func path(after flags: [String], in args: [String]) -> String? {
        args.firstIndex { flags.contains($0) }.flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
    }
}
