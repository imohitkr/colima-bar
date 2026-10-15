import Foundation

/// The clock of a VM against the clock of the Mac. A VM can fall behind while
/// the Mac sleeps. Lima 2.1 and later set the clock of the guest again every
/// 10 seconds. This is the fallback for older Lima and for a stopped guest agent.
enum ClockDrift {
    /// One measurement.
    struct Sample: Equatable {
        /// The VM time minus the Mac time, in seconds. A negative value means
        /// that the VM is behind.
        let offset: TimeInterval
        /// Half of the round trip: the offset is exact within this time.
        let uncertainty: TimeInterval
    }

    /// The offset, in seconds, from which a VM needs a fix. It is larger than
    /// the noise of a request and than the 100 ms that Lima allows.
    static let threshold: TimeInterval = 2

    /// The pause before the second measurement: two Lima periods. Lima can fix
    /// the clock itself in this time.
    static let limaGrace: Duration = .seconds(20)

    /// Compares `systemTime` (the `SystemTime` field of `GET /info`) with the
    /// middle of the request time. Returns nil if the text is not a time, or
    /// if the reply came before the request.
    static func sample(systemTime: String, sentAt: Date, receivedAt: Date) -> Sample? {
        guard let t = LogTime.parse(Substring(systemTime)), receivedAt >= sentAt else { return nil }
        let vm = Double(t.secs) + Double(t.nanos) / 1e9
        let round = receivedAt.timeIntervalSince(sentAt)
        let middle = sentAt.timeIntervalSince1970 + round / 2
        return Sample(offset: vm - middle, uncertainty: round / 2)
    }

    /// True if the clock is surely more than `threshold` off.
    static func needsFix(_ sample: Sample) -> Bool {
        abs(sample.offset) - sample.uncertainty > threshold
    }

    /// The command that steps the clock of the guest by the opposite of
    /// `offset`. GNU date adds the amount to its own clock when it runs, so
    /// the delay of ssh adds no error. `sudo -n` never asks for a password.
    /// The amount has the form `+37.250sec`, with no space.
    static func fixCommand(profile: String, offset: TimeInterval) -> [String] {
        let amount = String(format: "%+.3f", -offset) + "sec"
        return ["colima", "ssh", "--profile", profile, "--", "sudo", "-n", "date", "-s", amount]
    }
}
