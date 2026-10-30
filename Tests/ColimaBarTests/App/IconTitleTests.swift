import Testing

@testable import ColimaBar

@Suite struct IconTitleTests {
    private let pad = "\u{2007}"

    @Test func aCountOfOneDigitHasOneDigit() {
        #expect(IconTitle.format(count: 7, digits: 1) == " 7")
    }

    @Test func smallerCountsPadToTheWidestCount() {
        #expect(IconTitle.format(count: 15, digits: 3) == " \(pad)15")
        #expect(IconTitle.format(count: 5, digits: 3) == " \(pad)\(pad)5")
        #expect(IconTitle.format(count: 100, digits: 3) == " 100")
    }

    @Test func fourDigitsPadToFour() {
        #expect(IconTitle.format(count: 100, digits: 4) == " \(pad)100")
        #expect(IconTitle.format(count: 1000, digits: 4) == " 1000")
    }

    @Test func aWiderCountIsNeverCut() {
        #expect(IconTitle.format(count: 1234, digits: 2) == " 1234")
    }

    @Test func aCountOfZeroHasNoTitle() {
        #expect(IconTitle.format(count: 0, digits: 3).isEmpty)
    }
}
