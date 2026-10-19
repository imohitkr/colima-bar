/// Which profile a command shows.
enum CLIProfile {
    /// The profile that ColimaBar shows: its saved choice. A name that the
    /// script would refuse gives `default`.
    static func selected() -> String {
        guard let name = Defaults.string(.profile), ProfileName.isValid(name) else { return "default" }
        return name
    }

    /// The profile for a request: `--profile`, else the profile that ColimaBar shows.
    static func resolve(explicit: String?) -> String { explicit ?? selected() }
}
