import Foundation

/// Finds out whether the code runs inside a test process. The model uses it
/// to pick safe defaults: no real proxy and no real saved setting.
enum TestProcess {
    static let isRunning: Bool = {
        let env = ProcessInfo.processInfo.environment
        if env["XCTestConfigurationFilePath"] != nil || env["XCTestBundlePath"] != nil
            || env["SWIFT_TESTING_ENABLED"] != nil
        {
            return true
        }
        if NSClassFromString("XCTestCase") != nil { return true }
        let name = ProcessInfo.processInfo.processName
        return name.contains("xctest") || name.contains("swiftpm-testing-helper")
            || Bundle.main.bundlePath.hasSuffix(".xctest")
    }()

    /// A store that holds nothing and that no other process reads. It keeps
    /// its values in memory and writes no preferences file.
    static func emptyStore() -> UserDefaults { MemoryDefaults() }
}

/// A `UserDefaults` that never persists. It covers the calls that the model
/// and the tests use. A test must not create a preferences file.
private final class MemoryDefaults: UserDefaults {
    private let lock = NSLock()
    private var values: [String: Any] = [:]

    init() { super.init(suiteName: nil)! }

    override func object(forKey key: String) -> Any? { lock.withLock { values[key] } }
    override func set(_ value: Any?, forKey key: String) { lock.withLock { values[key] = value } }
    override func set(_ value: Bool, forKey key: String) { lock.withLock { values[key] = value } }
    override func removeObject(forKey key: String) { lock.withLock { values[key] = nil } }
    override func bool(forKey key: String) -> Bool { (object(forKey: key) as? Bool) ?? false }
    override func string(forKey key: String) -> String? { object(forKey: key) as? String }
}
