/// What the user asked the `colimabar` command to do. `CLIParser` makes it
/// from the arguments, and `CLIRunner` runs it.
struct CLIRequest: Equatable, Sendable {
    enum Command: String, CaseIterable, Sendable {
        case status, start, stop, restart, open, doctor, diagnostics, version, help
    }

    var command: Command
    /// The profile from `--profile`, or nil for the profile that ColimaBar shows.
    var profile: String?
    var json = false
    /// The PATH argument of `diagnostics`.
    var path: String?

    init(_ command: Command, profile: String? = nil, json: Bool = false, path: String? = nil) {
        self.command = command
        self.profile = profile
        self.json = json
        self.path = path
    }
}
