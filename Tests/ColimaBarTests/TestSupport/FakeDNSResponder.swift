import Foundation

@testable import ColimaBar

/// A stand-in for `DNSResponder` in model tests. It binds nothing.
/// `@unchecked Sendable`: `lock` guards the state.
final class FakeDNSResponder: DNSServing, @unchecked Sendable {
    private let lock = NSLock()
    private var zoneValue = ""
    private var bound: UInt16?
    private var ok = true
    private var startList: [UInt16] = []
    private var stopCount = 0
    private var failure: (@Sendable () -> Void)?

    var zone: String {
        get { lock.withLock { zoneValue } }
        set { lock.withLock { zoneValue = newValue } }
    }
    var port: UInt16? { lock.withLock { bound } }
    var onFailure: (@Sendable () -> Void)? {
        get { lock.withLock { failure } }
        set { lock.withLock { failure = newValue } }
    }
    /// False makes the next starts fail.
    var startSucceeds: Bool {
        get { lock.withLock { ok } }
        set { lock.withLock { ok = newValue } }
    }
    var starts: [UInt16] { lock.withLock { startList } }
    var stops: Int { lock.withLock { stopCount } }

    func start(port: UInt16) async -> Bool {
        lock.withLock {
            startList.append(port)
            bound = ok ? port : nil
            return ok
        }
    }

    func stop() {
        lock.withLock {
            stopCount += 1
            bound = nil
        }
    }

    /// The listener fails after it was ready.
    func fail() {
        let handler = lock.withLock { () -> (@Sendable () -> Void)? in
            bound = nil
            return failure
        }
        handler?()
    }
}

/// A fake `osascript` runner. It logs the scripts, answers with the queued
/// results and can write the resolver file like the root shell would.
/// `@unchecked Sendable`: `lock` guards the state.
final class FakeResolverRunner: @unchecked Sendable {
    private let lock = NSLock()
    private var scripts: [[String]] = []
    private var results: [Shell.Result] = []
    private var effect: (@Sendable () -> Void)?

    var calls: [[String]] { lock.withLock { scripts } }
    func queue(_ r: Shell.Result...) { lock.withLock { results = r } }
    /// Runs when a call succeeds, for example to write the file.
    func onSuccess(_ body: (@Sendable () -> Void)?) { lock.withLock { effect = body } }

    var runner: ResolverInstaller.Runner {
        { [self] args in
            let (result, run) = lock.withLock { () -> (Shell.Result, (@Sendable () -> Void)?) in
                scripts.append(args)
                let r = results.isEmpty ? Shell.Result(status: 0, out: "") : results.removeFirst()
                return (r, effect)
            }
            if result.ok { run?() }
            return result
        }
    }
}
