import Foundation
import Testing

@testable import ColimaBar

@Suite struct AppStatusTests {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func theJSONHasTheDocumentedShape() {
        let status = AppStatus(pid: 4242, version: "0.10.0", autoStopAt: ["default": t0])
        let text = String(decoding: status.encoded(), as: UTF8.self)
        #expect(
            text
                == #"{"autoStopAt":{"default":"2027-01-15T08:00:00Z"},"format":1,"pid":4242,"version":"0.10.0"}"#)
    }

    @Test func aStatusSurvivesAWriteAndARead() {
        let status = AppStatus(
            pid: 7, version: "0.10.0", autoStopAt: ["default": t0, "work": t0.addingTimeInterval(90)])
        #expect(AppStatus.decode(status.encoded()) == status)
        let none = AppStatus(pid: 7, version: "0.10.0", autoStopAt: [:])
        #expect(AppStatus.decode(none.encoded()) == none)
    }

    @Test func anotherFormatIsRefused() {
        #expect(AppStatus.decode(Data(#"{"format":2,"pid":7,"version":"x","autoStopAt":{}}"#.utf8)) == nil)
        #expect(AppStatus.decode(Data(#"{"pid":7,"version":"x","autoStopAt":{}}"#.utf8)) == nil)
    }

    @Test func dataThatIsNotAStatusIsRefused() {
        #expect(AppStatus.decode(Data()) == nil)
        #expect(AppStatus.decode(Data("[1]".utf8)) == nil)
        #expect(AppStatus.decode(Data(#"{"format":1,"pid":0,"version":"x","autoStopAt":{}}"#.utf8)) == nil)
        #expect(AppStatus.decode(Data(#"{"format":1,"pid":5,"version":"x","autoStopAt":{"a":"soon"}}"#.utf8)) == nil)
    }

    @Test func theFileNeedsAWriteForTheFirstTimeAndForAChangedSetOfProfiles() {
        #expect(AppStatus.needsWrite(old: nil, new: [:]))
        #expect(!AppStatus.needsWrite(old: [:], new: [:]))
        #expect(AppStatus.needsWrite(old: [:], new: ["default": t0]))  // a time appeared
        #expect(AppStatus.needsWrite(old: ["default": t0], new: [:]))  // a time went away
        #expect(AppStatus.needsWrite(old: ["default": t0], new: ["work": t0]))
    }

    @Test func aTimeThatMovesBySecondsNeedsAWriteAndASmallMoveDoesNot() {
        #expect(!AppStatus.needsWrite(old: ["default": t0], new: ["default": t0]))
        #expect(!AppStatus.needsWrite(old: ["default": t0], new: ["default": t0.addingTimeInterval(0.9)]))
        #expect(AppStatus.needsWrite(old: ["default": t0], new: ["default": t0.addingTimeInterval(1)]))
        #expect(AppStatus.needsWrite(old: ["default": t0], new: ["default": t0.addingTimeInterval(-5)]))
    }

    @Test func aStatusIsStaleWhenItsAppIsGone() {
        let status = AppStatus(pid: 7, version: "x", autoStopAt: [:])
        #expect(status.isStale(mtime: t0, now: t0.addingTimeInterval(5), ownerStarted: nil))
    }

    @Test func aStatusIsFreshWhileItsAppRunsEvenAfterManyHours() {
        let status = AppStatus(pid: 7, version: "x", autoStopAt: [:])
        let started = t0.addingTimeInterval(-3600)
        #expect(!status.isStale(mtime: t0, now: t0.addingTimeInterval(86400), ownerStarted: started))
    }

    @Test func aStatusIsStaleWhenAnotherProcessTookThePID() {
        let status = AppStatus(pid: 7, version: "x", autoStopAt: [:])
        // The process started 3 s or more after the file: it is not the writer.
        #expect(status.isStale(mtime: t0, now: t0.addingTimeInterval(60), ownerStarted: t0.addingTimeInterval(3)))
        #expect(!status.isStale(mtime: t0, now: t0.addingTimeInterval(60), ownerStarted: t0.addingTimeInterval(2)))
    }
}
