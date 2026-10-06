import Foundation

/// The limits and timings of a log window.
enum LogLimits {
    /// A window keeps at most this many lines.
    static let maxLines = 20_000
    /// A window keeps at most this much text, also when its lines are long.
    static let maxBytes = 32 << 20
    /// Lines may grow this far past `maxLines` before a trim. Trimming in
    /// batches keeps the cost of `removeFirst` low per line.
    static let trimSlack = 2000
    /// The text of all lines may grow by maxBytes / this before a trim.
    static let byteSlackDivisor = 16
    /// How long new lines wait, so that they are published as one batch.
    static let flushDelay = Duration.milliseconds(250)
    /// The first request asks for this many of the newest lines.
    static let initialTail = 1000
    /// The pause before the window tries the log request again.
    static let reconnectDelay = Duration.seconds(2)

    /// True when `lines` lines with `bytes` bytes of text passed the limits
    /// and their slack, so a trim is due.
    static func needsTrim(lines: Int, bytes: Int, maxLines: Int, maxBytes: Int) -> Bool {
        lines > maxLines + trimSlack || bytes > maxBytes + maxBytes / byteSlackDivisor
    }
}
