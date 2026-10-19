import Darwin
import Foundation

/// Where the `colimabar` command writes. `out` is for the answer (stdout),
/// and `err` is for messages (stderr). A test collects both.
struct CLIOutput {
    var out: @MainActor (String) -> Void
    var err: @MainActor (String) -> Void
    /// True if a person watches stderr. The command then shows what it waits for.
    var isTerminal: Bool

    /// The real stdout and stderr. A write to a closed pipe is ignored, so
    /// `colimabar status | head -n 1` does not end with an error.
    static let terminal = CLIOutput(
        out: { write($0, to: STDOUT_FILENO) }, err: { write($0, to: STDERR_FILENO) },
        isTerminal: isatty(STDERR_FILENO) != 0)

    private static func write(_ line: String, to fd: Int32) {
        let bytes = Array((line + "\n").utf8)
        var done = 0
        while done < bytes.count {
            let n = bytes.withUnsafeBufferPointer { Darwin.write(fd, $0.baseAddress! + done, bytes.count - done) }
            if n < 0, errno == EINTR { continue }
            if n <= 0 { return }
            done += n
        }
    }
}
