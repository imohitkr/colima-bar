import Foundation
import Testing

@testable import ColimaBar

@Suite struct IdleMinutesTests {
    @Test func acceptsWholeMinutesInRange() {
        #expect(IdleMinutes.parse("5") == 5)
        #expect(IdleMinutes.parse(" 90 ") == 90)
        #expect(IdleMinutes.parse("1440") == 1440)
    }

    @Test func rejectsOutOfRangeAndNonNumbers() {
        #expect(IdleMinutes.parse("0") == nil)
        #expect(IdleMinutes.parse("1441") == nil)
        #expect(IdleMinutes.parse("-3") == nil)
        #expect(IdleMinutes.parse("1.5") == nil)
        #expect(IdleMinutes.parse("abc") == nil)
        #expect(IdleMinutes.parse("") == nil)
    }

    @Test func appliesOnlyAValidChangedValue() {
        #expect(IdleMinutes.commit("45", current: 30) == 45)
        #expect(IdleMinutes.commit(" 90 ", current: 30) == 90)
        #expect(IdleMinutes.commit("1440", current: 30) == 1440)
        // The same value changes nothing, so the idle timer keeps running.
        #expect(IdleMinutes.commit("30", current: 30) == nil)
        // Invalid text stays in the field (red) and is never applied.
        for s in ["", "0", "1441", "-5", "4.5", "abc"] {
            #expect(IdleMinutes.commit(s, current: 30) == nil, "\(s)")
        }
    }
}
