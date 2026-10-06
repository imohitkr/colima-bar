import Foundation

/// Decides if a container alert may post a banner. The same key posts at most
/// once per `window` seconds. `clock` is replaceable for tests.
struct AlertThrottle {
    let window: TimeInterval
    let clock: () -> Date
    private var last: [String: Date] = [:]

    init(window: TimeInterval, clock: @escaping () -> Date = Date.init) {
        self.window = window
        self.clock = clock
    }

    /// The exit code is not part of the key. Thus a loop that exits with
    /// different codes still counts as one kind of alert.
    static func key(container: String, body: String) -> String {
        container + "|" + body.filter { !$0.isNumber }
    }

    /// True if `key` did not post within the window. A true result starts a new window.
    mutating func allow(_ key: String) -> Bool {
        let now = clock()
        if last.count > 100 { last = last.filter { now.timeIntervalSince($0.value) < window } }
        if let t = last[key], now.timeIntervalSince(t) < window { return false }
        last[key] = now
        return true
    }
}
