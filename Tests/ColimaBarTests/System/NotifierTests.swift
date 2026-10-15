import Testing

@testable import ColimaBar

@Suite struct NotifierTests {
    @Test func restartButtonGivesTheProfile() {
        let info: [AnyHashable: Any] = ["restartProfile": "work"]
        #expect(Notifier.profileToRestart(userInfo: info, action: "RESTART_VM") == "work")
    }

    @Test func bannerClickGivesNoProfile() {
        let info: [AnyHashable: Any] = ["restartProfile": "work"]
        #expect(
            Notifier.profileToRestart(userInfo: info, action: "com.apple.UNNotificationDefaultActionIdentifier") == nil)
    }

    @Test func containerAlertGivesNoProfile() {
        let info: [AnyHashable: Any] = ["id": "abc", "name": "web", "profile": "work"]
        #expect(Notifier.profileToRestart(userInfo: info, action: "RESTART") == nil)
        #expect(Notifier.profileToRestart(userInfo: info, action: "RESTART_VM") == nil)
    }

    @Test func invalidProfileNameGivesNoProfile() {
        #expect(Notifier.profileToRestart(userInfo: ["restartProfile": "a b"], action: "RESTART_VM") == nil)
        #expect(Notifier.profileToRestart(userInfo: ["restartProfile": ""], action: "RESTART_VM") == nil)
    }
}
