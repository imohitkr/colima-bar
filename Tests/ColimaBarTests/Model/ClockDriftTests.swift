import Foundation
import Testing

@testable import ColimaBar

@Suite struct ClockDriftTests {
    private let sent = Date(timeIntervalSince1970: 1_800_000_000)

    /// A sample of a VM whose clock is `offset` seconds after the middle of the request.
    private func sample(offset: Double, round: Double = 0.2) throws -> ClockDrift.Sample {
        let middle = sent.addingTimeInterval(round / 2)
        let vm = Int64((middle.timeIntervalSince1970 + offset).rounded(.down))
        let frac = middle.timeIntervalSince1970 + offset - Double(vm)
        let nanos = Int64((frac * 1e9).rounded())
        let date = Date(timeIntervalSince1970: TimeInterval(vm))
        let base = date.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false))
        let text = base + "." + String(format: "%09d", nanos) + "Z"
        return try #require(
            ClockDrift.sample(systemTime: text, sentAt: sent, receivedAt: sent.addingTimeInterval(round)))
    }

    @Test func offsetIsAgainstTheMiddleOfTheRequest() throws {
        let s = try #require(
            ClockDrift.sample(
                systemTime: "2027-01-15T08:00:10.5Z",
                sentAt: Date(timeIntervalSince1970: 1_800_000_000 + 0),
                receivedAt: Date(timeIntervalSince1970: 1_800_000_001)
            ))
        // 2027-01-15T08:00:00Z is 1_800_000_000. The middle is 0.5 s later.
        #expect(abs(s.offset - 10) < 0.001)
        #expect(abs(s.uncertainty - 0.5) < 0.001)
    }

    @Test func parsesNanosecondsAndZoneOffsets() throws {
        let sent = Date(timeIntervalSince1970: 1_800_000_000)
        let utc = try #require(
            ClockDrift.sample(systemTime: "2027-01-15T08:00:00.123456789Z", sentAt: sent, receivedAt: sent))
        let zone = try #require(
            ClockDrift.sample(systemTime: "2027-01-15T10:00:00.123456789+02:00", sentAt: sent, receivedAt: sent))
        #expect(abs(utc.offset - 0.123456789) < 0.000_001)
        #expect(abs(zone.offset - utc.offset) < 0.000_001)
    }

    @Test func badTextOrReversedTimesGiveNoSample() {
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(ClockDrift.sample(systemTime: "not a time", sentAt: t, receivedAt: t) == nil)
        #expect(ClockDrift.sample(systemTime: "", sentAt: t, receivedAt: t) == nil)
        #expect(
            ClockDrift.sample(systemTime: "2027-01-15T08:00:00Z", sentAt: t, receivedAt: t.addingTimeInterval(-1))
                == nil)
    }

    @Test func fixIsNeededOnlyAboveTheThreshold() {
        #expect(!ClockDrift.needsFix(.init(offset: 1.9, uncertainty: 0)))
        #expect(!ClockDrift.needsFix(.init(offset: 2.0, uncertainty: 0)))
        #expect(!ClockDrift.needsFix(.init(offset: -2.0, uncertainty: 0)))
        #expect(ClockDrift.needsFix(.init(offset: 2.1, uncertainty: 0)))
        #expect(!ClockDrift.needsFix(.init(offset: 2.1, uncertainty: 0.2)))
        #expect(ClockDrift.needsFix(.init(offset: -30, uncertainty: 0.2)))
        #expect(ClockDrift.needsFix(.init(offset: -2.1, uncertainty: 0)))
    }

    @Test func aMeasuredOffsetFeedsTheThreshold() throws {
        #expect(!ClockDrift.needsFix(try sample(offset: 0.05)))
        #expect(ClockDrift.needsFix(try sample(offset: -37.25)))
    }

    @Test func fixCommandStepsTheClockTheOtherWay() {
        #expect(
            ClockDrift.fixCommand(profile: "work", offset: -37.25)
                == ["colima", "ssh", "--profile", "work", "--", "sudo", "-n", "date", "-s", "+37.250sec"])
        #expect(ClockDrift.fixCommand(profile: "default", offset: 2.5).last == "-2.500sec")
    }

    @Test func fixAmountHasNoSpaceOrShellCharacter() throws {
        for offset in [-37.25, 2.5, -0.0004, 1234.5678, -86400] {
            let amount = try #require(ClockDrift.fixCommand(profile: "p", offset: offset).last)
            #expect(amount.wholeMatch(of: /[+-]\d+\.\d{3}sec/) != nil)
        }
    }
}
