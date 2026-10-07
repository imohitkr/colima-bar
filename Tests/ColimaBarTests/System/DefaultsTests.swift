import Testing

@testable import ColimaBar

@Suite struct DefaultsTests {
    /// The stored UserDefaults keys. A changed raw value loses the user's
    /// saved setting, so this list must change only on purpose.
    @Test func keysKeepTheirStoredNames() {
        let expected: Set<String> = [
            "profile", "notifyOnCrash", "autoStart", "autoStop", "autoStopMinutes", "hideIconWhenStopped",
            "toldIconHidden", "apiVersion", "checkUpdates", "notifiedVersion", "didOfferLoginItem",
            "didMigrateLoginItem", "revealOnLaunch", "keepRemovedLogs",
        ]
        #expect(Set(Defaults.Key.allCases.map(\.rawValue)) == expected)
    }
}
