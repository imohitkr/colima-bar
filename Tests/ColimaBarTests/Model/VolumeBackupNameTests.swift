import Foundation
import Testing

@testable import ColimaBar

@Suite struct VolumeBackupNameTests {
    private let date = Date(timeIntervalSince1970: 1_700_000_000)
    private let utc = TimeZone(identifier: "UTC")!

    @Test func theDefaultFileNameHasTheVolumeNameAndTheTime() {
        let name = VolumeBackupName.fileName(volume: "pgdata", isAnonymous: false, date: date, timeZone: utc)
        #expect(name == "pgdata-20231114-221320.tar")
    }

    @Test func charactersOutsideTheAllowedSetBecomeUnderscores() {
        let name = VolumeBackupName.fileName(volume: "my vol/é:1", isAnonymous: false, date: date, timeZone: utc)
        #expect(name == "my_vol___1-20231114-221320.tar")
    }

    @Test func anAnonymousVolumeUsesTheFirstTwelveCharacters() {
        let id = String(repeating: "ab12", count: 16)
        let name = VolumeBackupName.fileName(volume: id, isAnonymous: true, date: date, timeZone: utc)
        #expect(name == "ab12ab12ab12-20231114-221320.tar")
    }

    @Test func aLongVolumeNameIsCutToSixtyFourCharacters() {
        let name = VolumeBackupName.fileName(
            volume: String(repeating: "a", count: 100), isAnonymous: false, date: date, timeZone: utc)
        #expect(name == String(repeating: "a", count: 64) + "-20231114-221320.tar")
    }

    @Test(arguments: ["ab", "data", "a_b.c-d", "A1", String(repeating: "x", count: 128)])
    func aGoodNewNameIsValid(name: String) {
        #expect(VolumeBackupName.isValidNewName(name))
    }

    @Test(arguments: ["", "a", "_data", "-data", ".data", "da ta", "da/ta", "dät", String(repeating: "x", count: 129)])
    func aBadNewNameIsNotValid(name: String) {
        #expect(!VolumeBackupName.isValidNewName(name))
    }

    @Test func theSuggestionIsTheOriginalNameIfFree() {
        #expect(VolumeBackupName.suggestion(original: "pgdata", isTaken: false) == "pgdata")
    }

    @Test func theSuggestionAddsRestoredIfTheNameIsTaken() {
        #expect(VolumeBackupName.suggestion(original: "pgdata", isTaken: true) == "pgdata-restored")
    }

    @Test func theSuggestionHasAGoodNameWhenTheOriginalIsUnknown() {
        let name = VolumeBackupName.suggestion(original: nil, isTaken: false)
        #expect(VolumeBackupName.isValidNewName(name))
    }

    @Test func theSuggestionStaysWithinTheLimitWhenTaken() {
        let name = VolumeBackupName.suggestion(original: String(repeating: "x", count: 128), isTaken: true)
        #expect(VolumeBackupName.isValidNewName(name) && name.hasSuffix("-restored"))
    }

    @Test func twoVolumesWithTheSameFileNameGetDistinctNames() {
        let names = VolumeBackupName.fileNames(
            for: [("a/b", false), ("a_b", false), ("a:b", false)], date: date, timeZone: utc)
        #expect(names == ["a_b-20231114-221320.tar", "a_b-20231114-221320-2.tar", "a_b-20231114-221320-3.tar"])
    }

    @Test func aFileNameThatDiffersOnlyInCaseGetsASuffix() {
        let names = VolumeBackupName.fileNames(for: [("Data", false), ("data", false)], date: date, timeZone: utc)
        #expect(names == ["Data-20231114-221320.tar", "data-20231114-221320-2.tar"])
    }

    @Test func volumesWithDifferentNamesKeepTheirPlainNames() {
        let names = VolumeBackupName.fileNames(for: [("a", false), ("b", false)], date: date, timeZone: utc)
        #expect(names == ["a-20231114-221320.tar", "b-20231114-221320.tar"])
    }
}
