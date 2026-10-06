import Foundation

/// Decides which of the visible lines the list renders. SwiftUI places
/// every row of the list again when rows leave its head, so the list
/// renders only the newest lines. Search and Copy still use all lines.
enum LogTail {
    /// The list renders at least this many of the newest lines.
    static let limit = 2000
    /// While Follow is off, the rendered lines may grow this far past
    /// `limit` before the oldest ones leave the list. Rows then leave in
    /// batches, so the text that you read does not move with each new line.
    /// While Follow is on, rows leave with each batch: that costs less.
    static let slack = 2000

    /// Returns the new index of the first rendered line, when `count` lines
    /// are visible and the list rendered from `current` before.
    static func start(current: Int, count: Int, limit: Int = limit, slack: Int = slack) -> Int {
        let s = min(max(0, current), count)
        return count - s > limit + slack ? count - limit : s
    }

    /// The index of the first rendered line after a new filter or a clear.
    static func reset(count: Int, limit: Int = limit) -> Int { max(0, count - limit) }
}
