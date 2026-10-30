import Testing

@testable import ColimaBar

@Suite struct ComposeVerbTests {
    @Test func eachVerbRunsItsOwnCtlAction() {
        #expect(ComposeVerb.pull.action == .composePull)
        #expect(ComposeVerb.up.action == .composeUp)
        #expect(ComposeVerb.down.action == .composeDown)
        #expect(ComposeVerb.remove.action == .composeRemove)
    }

    @Test func theActionsAreNotVMActions() {
        for verb in ComposeVerb.allCases {
            #expect(!verb.action.isVMAction, "\(verb)")
            #expect(verb.action.busyLabel(running: true) == nil, "\(verb)")
        }
    }
}
