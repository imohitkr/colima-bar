import Foundation

@testable import ColimaBar

/// A fake tool runner that records the arguments of each call and answers
/// with one status, or with the output of a table keyed by the arguments.
final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [[String]] = []

    var all: [[String]] { lock.withLock { calls } }

    func run(status: Int32 = 0, out: [[String]: String] = [:]) -> ContextRunner.Run {
        { [self] args, _ in
            lock.withLock { calls.append(args) }
            return Shell.Result(status: status, out: out[args] ?? "")
        }
    }
}
