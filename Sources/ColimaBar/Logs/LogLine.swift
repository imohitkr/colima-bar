import Foundation

struct LogLine: Identifiable, Equatable {
    /// Set by `LogBuffer` when the line enters the store.
    var id: Int
    let time: String  // HH:mm:ss.SSS, local time
    let text: String
    let isStderr: Bool

    init(id: Int, time: String, text: String, isStderr: Bool) {
        self.id = id
        self.time = time
        self.text = text
        self.isStderr = isStderr
    }

    /// Builds a line from "2026-10-02T14:03:11.123456789Z message" on the
    /// reader thread. Also returns the timestamp, which `since` needs later.
    /// A line without a valid timestamp keeps all its text.
    static func parse(_ raw: String, isStderr: Bool) -> (line: LogLine, timestamp: Substring?) {
        // RFC 3339 timestamps are at most 35 bytes, so look no further.
        if let sp = raw.utf8.prefix(40).firstIndex(of: 0x20) {
            let ts = raw[..<sp]
            if let t = LogTime.parse(ts) {
                let text = String(raw[raw.utf8.index(after: sp)...])
                return (
                    LogLine(id: 0, time: LogTime.clock(secs: t.secs, nanos: t.nanos), text: text, isStderr: isStderr),
                    ts
                )
            }
        }
        return (LogLine(id: 0, time: "", text: raw, isStderr: isStderr), nil)
    }
}
