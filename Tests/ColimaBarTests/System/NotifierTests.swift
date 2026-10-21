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

    @Test func mutedAlertSkipsTheBannerAndTheThrottle() {
        var throttle = AlertThrottle(window: 600)
        let ref = ContainerRef(id: "a", name: "web")
        #expect(!Notifier.admitsBanner(false, container: ref, body: "Exited with code 1", throttle: &throttle))
        // The muted alert did not start the window: the first banner after an unmute shows.
        #expect(Notifier.admitsBanner(true, container: ref, body: "Exited with code 1", throttle: &throttle))
    }

    @Test func throttledAlertGivesNoBanner() {
        var throttle = AlertThrottle(window: 600)
        let ref = ContainerRef(id: "a", name: "web")
        #expect(Notifier.admitsBanner(true, container: ref, body: "Exited with code 1", throttle: &throttle))
        #expect(!Notifier.admitsBanner(true, container: ref, body: "Exited with code 2", throttle: &throttle))
    }

    @MainActor @Test func mutedPostRecordsOnceAndSendsNoBanner() {
        let notifier = Notifier()
        var seen: [String] = []
        notifier.onAlert = { _, body, _ in seen.append(body) }
        let ref = ContainerRef(id: "a", name: "web")
        let sent = notifier.post("Exited with code 1", title: "web", container: ref, banner: false)
        #expect(!sent)
        #expect(seen == ["Exited with code 1"])
    }

    @MainActor @Test func unrecordedMutedPostCallsNoOnAlert() {
        let notifier = Notifier()
        var count = 0
        notifier.onAlert = { _, _, _ in count += 1 }
        let ref = ContainerRef(id: "a", name: "web")
        #expect(!notifier.post("Healthy again", title: "web", container: ref, record: false, banner: false))
        #expect(count == 0)
    }

    @Test func alertWithoutAContainerIsNotThrottled() {
        var throttle = AlertThrottle(window: 600)
        #expect(Notifier.admitsBanner(true, container: nil, body: "Update", throttle: &throttle))
        #expect(Notifier.admitsBanner(true, container: nil, body: "Update", throttle: &throttle))
    }
}
