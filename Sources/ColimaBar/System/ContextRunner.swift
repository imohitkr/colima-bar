import Foundation

/// How the context switchers run `docker` and `kubectl`: with the arguments
/// and a time limit in seconds. Tests pass a fake that records the arguments.
/// The system runner refuses in a test process, so no test reaches a real tool.
enum ContextRunner {
    typealias Run = @Sendable ([String], TimeInterval) async -> Shell.Result

    static let system: Run = { args, timeout in
        guard !TestProcess.isRunning else { return Shell.Result(status: -1, out: "no tool in a test") }
        return await Shell.run(args, timeout: timeout)
    }
}
