import Foundation
import Testing

@testable import ColimaBar

/// The read-only model of the `colimabar` command.
@MainActor @Suite struct ColimaModelReadOnlyTests {
    @Test func aReadOnlyModelShowsTheNamedProfileAndCountsAsADebugRun() {
        let model = ColimaModel(profile: "work", readOnly: true)
        #expect(model.profile == "work")
        #expect(model.isDebug)
    }

    @Test func aReadOnlyModelDoesNotSaveTheProfile() {
        let before = Defaults.string(.profile)
        _ = ColimaModel(profile: "read-only-test-profile", readOnly: true)
        #expect(Defaults.string(.profile) == before)
    }

    @Test func aNormalModelIsNotADebugRun() {
        #expect(!ColimaModel().isDebug)
    }
}
