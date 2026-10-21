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

    /// A store that holds nothing and that no other process reads.
    static func emptyStore() -> UserDefaults {
        let name = "colimabar.test.\(UUID().uuidString)"
        let store = UserDefaults(suiteName: name) ?? .standard
        store.removePersistentDomain(forName: name)
        return store
    }
}
