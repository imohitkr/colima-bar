import Foundation
import Testing

@testable import ColimaBar

@Suite struct LatestOnlyTests {
    @Test func olderResultAfterANewerOneIsDropped() {
        var o = LatestOnly()
        let a = o.begin()
        let b = o.begin()
        let newer = o.apply(b)  // newer "Stopped" applies first
        let older = o.apply(a)  // older "Running" ends later: dropped
        #expect(newer && !older)
        #expect(o.isLatestApplied(b))
        #expect(!o.isLatestApplied(a))
    }

    @Test func olderResultAppliesWhenTheNewerOneGaveNothing() {
        var o = LatestOnly()
        let a = o.begin()
        _ = o.begin()  // fails, never applies
        let applied = o.apply(a)
        #expect(applied)
    }

    @Test func laterStepOfAnOlderCallIsDropped() {
        var o = LatestOnly()
        let a = o.begin()
        let first = o.apply(a)  // `colima list` applied, `colima status` runs
        let b = o.begin()
        let second = o.apply(b)
        #expect(first && second)
        #expect(!o.isLatestApplied(a))
    }
}
