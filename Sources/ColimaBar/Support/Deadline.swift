import Foundation
import os

/// Gives an async operation a time limit that it cannot ignore.
enum Deadline {
    /// Lets the first caller resume, and holds the timer task so the winner
    /// of the race can cancel it.
    private final class Once: Sendable {
        private struct State {
            var done = false
            var timer: Task<Void, Never>?
        }
        private let state = OSAllocatedUnfairLock(initialState: State())

        /// True for the first call only.
        func first() -> Bool {
            state.withLock { s in
                defer { s.done = true }
                return !s.done
            }
        }

        /// Keeps the timer. If the work has won already, it cancels at once.
        func setTimer(_ t: Task<Void, Never>) {
            let cancelNow = state.withLock { s -> Bool in
                s.timer = t
                return s.done
            }
            if cancelNow { t.cancel() }
        }

        func cancelTimer() {
            let t = state.withLock { $0.timer }
            t?.cancel()
        }
    }

    /// The result of `op`, or `fallback` if `op` has not finished after
    /// `seconds`. `op` gets a cancel then, but it can run on: a task group
    /// would wait for `Shell.run`, which ignores a cancel. Thus this runs
    /// `op` and the timer in two tasks that are not children, and the first
    /// one to finish resumes the caller.
    static func run<T: Sendable>(
        seconds: TimeInterval, fallback: T, _ op: @escaping @Sendable () async -> T
    ) async -> T {
        let once = Once()
        return await withCheckedContinuation { (cont: CheckedContinuation<T, Never>) in
            let work = Task {
                let value = await op()
                if once.first() {
                    once.cancelTimer()
                    cont.resume(returning: value)
                }
            }
            once.setTimer(
                Task {
                    // A cancel ends the sleep: the work has won.
                    guard (try? await Task.sleep(for: .seconds(max(0, seconds)))) != nil else { return }
                    if once.first() {
                        work.cancel()
                        cont.resume(returning: fallback)
                    }
                })
        }
    }
}
