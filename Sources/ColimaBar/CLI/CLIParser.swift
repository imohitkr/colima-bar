/// Reads the arguments of the `colimabar` command. It uses no library: the
/// rules are small, and a test checks each one. The parser changes nothing.
enum CLIParser {
    enum Outcome: Equatable {
        case run(CLIRequest)
        /// The arguments are wrong. The text says why.
        case usageError(String)
    }

    /// `args` are the arguments after the program name.
    static func parse(_ args: [String]) -> Outcome {
        guard let first = args.first else { return .run(CLIRequest(.help)) }
        switch first {
        case "-h", "--help": return .run(CLIRequest(.help))
        case "--version": return .run(CLIRequest(.version))
        default: break
        }
        guard let command = CLIRequest.Command(rawValue: first) else {
            return .usageError(first.hasPrefix("-") ? "Unknown option: \(first)." : "Unknown command: \(first).")
        }
        return parse(command, Array(args.dropFirst()))
    }

    /// The options that each command takes.
    private static func takesProfile(_ c: CLIRequest.Command) -> Bool {
        switch c {
        case .status, .start, .stop, .restart, .doctor, .diagnostics: true
        case .open, .version, .help: false
        }
    }

    private static func takesJSON(_ c: CLIRequest.Command) -> Bool { c == .status || c == .doctor }

    private static func parse(_ command: CLIRequest.Command, _ rest: [String]) -> Outcome {
        var request = CLIRequest(command)
        var profileSeen = false
        var onlyArguments = false
        var i = 0
        while i < rest.count {
            let word = rest[i]
            i += 1
            if onlyArguments || !word.hasPrefix("-") || word == "-" {
                guard command == .diagnostics, request.path == nil else {
                    return .usageError("Unexpected argument: \(word).")
                }
                request.path = word
                continue
            }
            switch word {
            case "--":
                onlyArguments = true
            case "-h", "--help":
                return .run(CLIRequest(.help))
            case "--json":
                guard takesJSON(command) else { return .usageError(notFor(word, command)) }
                guard !request.json else { return .usageError("The option --json is given twice.") }
                request.json = true
            case "-p", "--profile":
                guard takesProfile(command) else { return .usageError(notFor("--profile", command)) }
                guard !profileSeen else { return .usageError("The option --profile is given twice.") }
                profileSeen = true
                guard i < rest.count, !rest[i].hasPrefix("-") else {
                    return .usageError("The option --profile needs a name.")
                }
                i += 1
                if let problem = profileProblem(rest[i - 1]) { return .usageError(problem) }
                request.profile = rest[i - 1]
            case _ where word.hasPrefix("--profile="):
                guard takesProfile(command) else { return .usageError(notFor("--profile", command)) }
                guard !profileSeen else { return .usageError("The option --profile is given twice.") }
                profileSeen = true
                let name = String(word.dropFirst("--profile=".count))
                guard !name.isEmpty else { return .usageError("The option --profile needs a name.") }
                if let problem = profileProblem(name) { return .usageError(problem) }
                request.profile = name
            default:
                return .usageError("Unknown option: \(word).")
            }
        }
        return .run(request)
    }

    private static func notFor(_ option: String, _ command: CLIRequest.Command) -> String {
        "The option \(option) does not work with \(command.rawValue)."
    }

    /// Why `name` is not a profile name, or nil. The script accepts the name
    /// only if it passes `ProfileName.isValid`. Colima reads `colima` as
    /// `default` and `colima-X` as `X`, so the command refuses both: the
    /// docker context and the socket would name another profile.
    static func profileProblem(_ name: String) -> String? {
        if name == "colima" { return "Colima reads the name colima as default. Use default." }
        if name.hasPrefix("colima-") {
            let rest = String(name.dropFirst("colima-".count))
            if ProfileName.isValid(rest) { return "Colima reads the name \(name) as \(rest). Use \(rest)." }
            if rest.isEmpty { return "Colima reads the name \(name) as default. Use default." }
        }
        guard ProfileName.isValid(name) else {
            return "The profile name is not valid: \(name). Use letters, digits, \".\", \"_\" and \"-\"."
        }
        return nil
    }
}
