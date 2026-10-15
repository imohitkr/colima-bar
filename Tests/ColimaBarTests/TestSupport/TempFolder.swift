import Foundation

/// A temporary folder that goes away with the test.
final class TempFolder {
    let path = NSTemporaryDirectory() + "cb-temp-\(UUID().uuidString.prefix(8))"
    init() throws { try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true) }
    deinit { try? FileManager.default.removeItem(atPath: path) }
}
