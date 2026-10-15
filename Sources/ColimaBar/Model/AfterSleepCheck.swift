import Foundation

/// The rules for the check after the Mac slept.
enum AfterSleepCheck {
    /// The running profiles with a docker socket and a valid name, except
    /// the `blocked` ones: a profile with an action or an auto-start now
    /// reports its own failures.
    static func profiles(_ rows: [ProfileRow], blocked: Set<String>) -> [String] {
        rows.filter {
            $0.isRunning && ColimaModel.hasDockerSocket(runtime: $0.runtime) && ProfileName.isValid($0.name)
                && !blocked.contains($0.name)
        }
        .map(\.name)
    }

    /// The pause before each ping of the Colima socket. With the time-outs,
    /// the check ends in about 30 seconds.
    static let pingDelays: [Duration] = [.seconds(0), .seconds(1), .seconds(2), .seconds(4), .seconds(8)]

    /// The time-out of one ping, in seconds.
    static let pingTimeout = 3

    static func noAnswerText(profile: String) -> String {
        "Docker does not answer in the VM of profile \(profile) after the Mac slept. Click Restart to restart the VM."
    }

    static func restartMissingText(profile: String) -> String {
        "Profile \(profile) no longer exists, so ColimaBar did not restart it."
    }

    static func restartBusyText(profile: String) -> String {
        "Wait until the action of the profile \(profile) ends."
    }

    static func restartStoppedText(profile: String) -> String {
        "The VM of profile \(profile) is stopped, so ColimaBar did not restart it."
    }

    /// `offset` is the VM time minus the Mac time.
    static func clockText(profile: String, offset: TimeInterval) -> String {
        let seconds = Int(abs(offset).rounded())
        let side = offset < 0 ? "behind" : "ahead of"
        return
            "The clock of the VM of profile \(profile) is \(seconds) seconds \(side) the Mac. ColimaBar could not set it. Click Restart to restart the VM."
    }
}
