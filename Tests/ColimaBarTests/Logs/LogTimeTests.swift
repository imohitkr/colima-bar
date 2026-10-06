import Foundation
import Testing

@testable import ColimaBar

@Suite struct LogTimeTests {
    /// The reference value comes from Foundation, which the app used before.
    private func epoch(_ s: String) -> Int64 {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return Int64(f.date(from: s)!.timeIntervalSince1970)
    }

    @Test func parsesZeroThreeSixAndNineFractionalDigits() {
        let secs = epoch("2026-10-02T14:03:11Z")
        #expect(LogTime.parse("2026-10-02T14:03:11Z")! == (secs, 0))
        #expect(LogTime.parse("2026-10-02T14:03:11.123Z")! == (secs, 123_000_000))
        #expect(LogTime.parse("2026-10-02T14:03:11.123456Z")! == (secs, 123_456_000))
        #expect(LogTime.parse("2026-10-02T14:03:11.123456789Z")! == (secs, 123_456_789))
    }

    @Test func matchesFoundationOverManyDates() {
        // Covers leap years, month ends and both sides of 1970.
        for s in [
            "1970-01-01T00:00:00Z", "1969-12-31T23:59:59Z", "2000-02-29T12:00:00Z",
            "2024-12-31T23:59:59Z", "2100-03-01T00:00:00Z", "2038-01-19T03:14:08Z",
        ] {
            #expect(LogTime.parse(Substring(s))?.secs == epoch(s), "\(s)")
        }
    }

    @Test func acceptsZoneOffsetsAndLowerCase() {
        let secs = epoch("2026-10-02T12:03:11Z")
        #expect(LogTime.parse("2026-10-02T14:03:11+02:00")?.secs == secs)
        #expect(LogTime.parse("2026-10-02T09:33:11.5-02:30")! == (secs, 500_000_000))
        #expect(LogTime.parse("2026-10-02t12:03:11z")?.secs == secs)
    }

    @Test func cutsDigitsPastNine() {
        #expect(LogTime.parse("1970-01-01T00:00:01.1234567891Z")! == (1, 123_456_789))
    }

    @Test func rejectsInvalidTimestamps() {
        for s in [
            "", "nope", "2026-10-02T14:03:11", "2026-10-02T14:03:11.Z", "2026-02-30T00:00:00Z",
            "2026-13-01T00:00:00Z", "2026-10-02T24:00:00Z", "2026-10-02 14:03:11Z",
            "2026-10-02T14:03:11Zjunk", "2026-10-02T14:03:11+0200", "404 not found",
        ] {
            #expect(LogTime.parse(Substring(s)) == nil, "\(s)")
        }
    }

    @Test func clockMatchesDateFormatterInLocalTime() {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        // Half a year apart, so one of them is in daylight saving time
        // where the local zone has it.
        let cases = [
            ("2026-01-15T08:09:10.987654321Z", ".987"), ("2026-07-15T23:59:59.001Z", ".001"),
            ("2026-03-29T01:30:00Z", ".000"),
        ]
        for (s, ms) in cases {
            let t = LogTime.parse(Substring(s))!
            let date = Date(timeIntervalSince1970: TimeInterval(t.secs))
            #expect(LogTime.clock(secs: t.secs, nanos: t.nanos) == f.string(from: date) + ms, "\(s)")
        }
    }

    @Test @MainActor func clockTrimsNanoseconds() {
        let t = LogStore.clock("2026-10-02T14:03:11.123456789Z")
        #expect(t.count == 12)  // HH:mm:ss.SSS in local time
        #expect(t.hasSuffix("11.123"))
        #expect(LogStore.clock("garbage") == "")
    }
}
