/// The exit codes of the `colimabar` command. Scripts read them, so a
/// number never changes its meaning.
enum CLIExit {
    /// Done. For `doctor`: no problem.
    static let done: Int32 = 0
    /// Failed, or Doctor found a problem.
    static let failed: Int32 = 1
    /// The arguments are wrong.
    static let usage: Int32 = 2
    /// Not done: another VM action holds the lock of the profile.
    static let locked: Int32 = 3
    /// SIGINT. SIGTERM gives 143.
    static let interrupted: Int32 = 130
    static let terminated: Int32 = 143

    /// The exit code for the status of `colima-ctl.sh`. The script exits
    /// with 2 when another action holds its lock. Any other value but 0
    /// is a failure, also -1 (the script did not start).
    static func forScript(status: Int32) -> Int32 {
        switch status {
        case 0: done
        case 2: locked
        default: failed
        }
    }

    /// The exit code for a stop by a signal: 130 for SIGINT, 143 for SIGTERM.
    static func forSignal(_ signal: Int32) -> Int32 {
        signal == 2 ? interrupted : terminated
    }

    /// The exit code for a Doctor report: 1 if it has a problem. A warning is not a problem.
    static func forDoctor(_ report: DoctorReport) -> Int32 {
        report.problems > 0 ? failed : done
    }

    /// The exit code for `status`: 0 if the profile is listed by Colima.
    static func forStatus(_ state: CLIStatus.State) -> Int32 {
        switch state {
        case .running, .stopped, .broken: done
        case .missing, .notInstalled, .unknown: failed
        }
    }
}
