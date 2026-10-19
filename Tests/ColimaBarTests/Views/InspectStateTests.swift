import Foundation
import Testing

@testable import ColimaBar

@MainActor @Suite struct InspectStateTests {
    @Test func aValueIsHiddenUntilTheUserShowsIt() {
        let state = InspectState()
        #expect(!state.isRevealed("env:API_KEY"))
        state.toggle("env:API_KEY")
        #expect(state.isRevealed("env:API_KEY"))
        #expect(!state.isRevealed("env:OTHER"))
        state.toggle("env:API_KEY")
        #expect(!state.isRevealed("env:API_KEY"))
    }

    @Test func closingThePageDropsTheDetailAndTheShownValues() {
        let ui = ViewState()
        ui.inspectID = "abc"
        ui.inspect.toggle("env:API_KEY")
        ui.inspect.gone = true
        ui.inspectID = nil
        #expect(ui.inspect.detail == nil)
        #expect(!ui.inspect.gone)
        #expect(!ui.inspect.isRevealed("env:API_KEY"))
    }

    @Test func openingAnotherContainerHidesTheShownValues() {
        let ui = ViewState()
        ui.inspectID = "abc"
        ui.inspect.toggle("env:API_KEY")
        ui.inspectID = "def"
        #expect(!ui.inspect.isRevealed("env:API_KEY"))
    }

    private func detail() -> ContainerDetail {
        let api = try? JSONDecoder().decode(APIContainerDetail.self, from: Data(#"{"Id": "abc"}"#.utf8))
        return ContainerDetail.make(from: api!, digests: [])
    }

    @Test func theFirstFailedReadShowsTheProblemAtOnce() {
        let state = InspectState()
        #expect(state.problem == nil)
        _ = state.recordFailure("HTTP 500")
        #expect(state.problem == "ColimaBar could not read this container (HTTP 500).")
    }

    @Test func aFailureAfterAGoodReadShowsTheProblemOnlyAfter3InARow() {
        let state = InspectState()
        state.recordFound(detail())
        _ = state.recordFailure("HTTP 500")
        _ = state.recordFailure("HTTP 500")
        #expect(state.problem == nil)
        #expect(state.isStale)
        _ = state.recordFailure("HTTP 500")
        #expect(state.problem != nil)
        state.recordFound(detail())
        #expect(state.problem == nil)
        #expect(!state.isStale)
        #expect(state.failedReads == 0)
    }

    @Test func aReadWithNoAnswerMarksTheDetailStaleWithoutAProblem() {
        let state = InspectState()
        state.recordFound(detail())
        state.recordUnavailable()
        #expect(state.isStale)
        #expect(state.problem == nil)
    }

    @Test func aFailureIsLoggedOnceForEachOpen() {
        let state = InspectState()
        #expect(state.recordFailure("HTTP 500"))
        #expect(!state.recordFailure("HTTP 500"))
        state.reset()
        #expect(state.recordFailure("HTTP 500"))
    }
}
