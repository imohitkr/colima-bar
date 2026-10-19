/// The texts of the `colimabar` command that do not depend on the VM.
enum CLIHelp {
    static let text = """
        Usage: colimabar COMMAND [OPTIONS]

        Commands:
          status [--json] [--profile NAME]    Show the VM, auto-start, auto-stop and the socket.
          start [--profile NAME]              Start the VM. Wait until Docker is ready.
          stop [--profile NAME]               Stop the VM.
          restart [--profile NAME]            Stop and start the VM. Wait until Docker is ready.
          open                                Open the dashboard. Start ColimaBar if it does not run.
          doctor [--json] [--profile NAME]    Run the Doctor checks.
          diagnostics [--profile NAME] [PATH] Write the diagnostics file to PATH, a file or a
                                              folder. The default is the current folder.
          version                             Show the version.
          help                                Show this help.

        Options:
          -p, --profile NAME  The Colima profile. The default is the profile that ColimaBar shows.
          --json              Write JSON for scripts (schemaVersion 1).

        Exit codes:
          0    Done. Doctor found no problem.
          1    Failed, or Doctor found a problem.
          2    Usage error.
          3    Not done: another VM action holds the lock of the profile.
          130/143  Interrupted (SIGINT or SIGTERM).

        status, doctor and diagnostics never start the VM. ColimaBar does not need to run.
        """

    static func version(_ version: String) -> String { "colimabar \(version)" }

    /// The text after a usage error, on stderr.
    static func usageError(_ message: String) -> String {
        "colimabar: \(message)\nRun `colimabar help` to see the commands."
    }
}
