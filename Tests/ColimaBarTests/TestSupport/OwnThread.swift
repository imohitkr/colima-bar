import Foundation

/// Runs `body` on a new thread and returns its result.
///
/// Use it for a blocking call (a socket read, a semaphore wait) in an async
/// test. Swift's cooperative pool has only one thread for each core, and the
/// code under test needs it too, for example for the Task that runs wake().
/// If blocked tests hold all its threads, that Task waits until a test times out.
func onOwnThread<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
    await withCheckedContinuation { c in
        Thread.detachNewThread { c.resume(returning: body()) }
    }
}
