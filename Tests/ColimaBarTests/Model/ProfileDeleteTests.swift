import Testing

@testable import ColimaBar

@Suite struct ProfileDeleteTests {
    @Test func aRunningSelectedProfileMustStopFirst() {
        #expect(ProfileDelete.refusal(profile: "work", selected: "work", isRunning: true) != nil)
        #expect(ProfileDelete.refusal(profile: "work", selected: "work", isRunning: false) == nil)
        // Another profile can be deleted while it runs: colima delete stops it.
        #expect(ProfileDelete.refusal(profile: "work", selected: "default", isRunning: true) == nil)
    }

    @Test func theWarningNamesTheProfileAndWarnsMoreForDefault() {
        let work = ProfileDelete.warning(profile: "work", isRunning: false)
        #expect(work.contains("profile work"))
        #expect(work.hasSuffix("type the profile name: work"))
        #expect(!work.contains("main Colima profile"))
        #expect(ProfileDelete.warning(profile: "default", isRunning: false).contains("main Colima profile"))
        #expect(ProfileDelete.warning(profile: "work", isRunning: true).contains("Its containers stop."))
    }

    @Test func onlyTheTypedNameConfirms() {
        #expect(ProfileDelete.confirms(typed: " work ", profile: "work"))
        #expect(!ProfileDelete.confirms(typed: "Work", profile: "work"))
        #expect(!ProfileDelete.confirms(typed: "", profile: "work"))
    }

    @Test func aDeletedSelectedProfileSwitchesToDefault() {
        #expect(ProfileDelete.nextSelection(deleted: "work", selected: "work", remaining: ["default"]) == "default")
        #expect(ProfileDelete.nextSelection(deleted: "work", selected: "dev", remaining: ["default", "dev"]) == "dev")
        // default itself: the first remaining profile, else default.
        #expect(ProfileDelete.nextSelection(deleted: "default", selected: "default", remaining: ["dev"]) == "dev")
        #expect(ProfileDelete.nextSelection(deleted: "default", selected: "default", remaining: []) == "default")
    }
}
