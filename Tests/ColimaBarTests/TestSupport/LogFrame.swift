import Foundation

/// Builds the stdout and stderr frames that Docker sends for the logs of a
/// container without a TTY.
enum LogFrame {
    /// One frame: stream 1 is stdout, stream 2 is stderr.
    static func make(_ stream: UInt8, _ s: String) -> Data {
        let payload = Data(s.utf8)
        let n = UInt32(payload.count)
        return Data([stream, 0, 0, 0, UInt8(n >> 24), UInt8(n >> 16 & 0xff), UInt8(n >> 8 & 0xff), UInt8(n & 0xff)])
            + payload
    }
}
