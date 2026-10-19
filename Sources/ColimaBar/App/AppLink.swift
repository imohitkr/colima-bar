import Foundation

/// A `colimabar://` link, parsed. The parser is pure and uses only
/// `URLComponents`. A link only opens the dashboard or Doctor, or starts,
/// stops or restarts a VM. It never returns data, writes a file or reaches a
/// shell: its only parameter is a profile name, which must pass
/// `ProfileName.isValid`.
enum AppLink: Equatable, Sendable {
    case open
    case doctor
    /// `profile` is nil when the link names none. The link then uses the
    /// selected profile at the time it runs.
    case vm(VMAction, profile: String?)

    /// The VM actions that a link can run. The raw value is the route.
    enum VMAction: String, CaseIterable, Sendable {
        case start
        case stop
        case restart

        var ctl: CtlAction {
            switch self {
            case .start: .start
            case .stop: .stop
            case .restart: .restart
            }
        }
    }

    /// Why a text is not a link that ColimaBar runs. The cases carry no text
    /// of the input, so a message or a log line cannot repeat it.
    enum Failure: Error, Equatable, Sendable {
        case tooLong
        case malformed
        case wrongScheme
        case unknownRoute
        case badParameter
        case badProfile

        /// A fixed word for the log.
        var kind: String {
            switch self {
            case .tooLong: "tooLong"
            case .malformed: "malformed"
            case .wrongScheme: "wrongScheme"
            case .unknownRoute: "unknownRoute"
            case .badParameter: "badParameter"
            case .badProfile: "badProfile"
            }
        }
    }

    static let scheme = "colimabar"
    /// The longest link in UTF-8 bytes. A real link is far shorter.
    static let maxBytes = 1024
    /// The longest profile name in UTF-8 bytes.
    static let maxProfileBytes = 100

    /// The route, for the log.
    var route: String {
        switch self {
        case .open: "open"
        case .doctor: "doctor"
        case .vm(let action, _): action.rawValue
        }
    }

    var profile: String? {
        if case .vm(_, let profile) = self { return profile }
        return nil
    }

    /// Parses `text`.
    /// - The scheme is `colimabar` in any case.
    /// - The route is the raw host of `colimabar://ROUTE`, or the path of
    ///   `colimabar:ROUTE`. It is never percent-decoded, so `st%61rt` fails.
    /// - Only `profile` is a parameter, once, on start, stop and restart.
    ///   The profile is decoded once and must pass `ProfileName.isValid`.
    static func parse(_ text: String) -> Result<AppLink, Failure> {
        guard text.utf8.count <= maxBytes else { return .failure(.tooLong) }
        guard let parts = URLComponents(string: text) else { return .failure(.malformed) }
        guard parts.scheme?.lowercased() == scheme else { return .failure(.wrongScheme) }
        guard parts.user == nil, parts.password == nil, parts.port == nil, parts.fragment == nil else {
            return .failure(.malformed)
        }
        let route: String
        if let host = parts.percentEncodedHost {
            // colimabar://ROUTE, with no path or a single "/".
            let path = parts.percentEncodedPath
            guard path.isEmpty || path == "/" else { return .failure(.malformed) }
            route = host
        } else {
            // colimabar:ROUTE
            let path = parts.percentEncodedPath
            guard !path.contains("/") else { return .failure(.malformed) }
            route = path
        }
        let items = parts.percentEncodedQueryItems ?? []
        switch asciiLowercased(route) {
        case "open": return noParameters(items, .open)
        case "doctor": return noParameters(items, .doctor)
        case let name:
            guard let action = VMAction(rawValue: name) else { return .failure(.unknownRoute) }
            return vmLink(action, items)
        }
    }

    private static func noParameters(_ items: [URLQueryItem], _ link: AppLink) -> Result<AppLink, Failure> {
        items.isEmpty ? .success(link) : .failure(.badParameter)
    }

    private static func vmLink(_ action: VMAction, _ items: [URLQueryItem]) -> Result<AppLink, Failure> {
        guard items.allSatisfy({ asciiLowercased($0.name) == "profile" }), items.count <= 1 else {
            return .failure(.badParameter)
        }
        guard let item = items.first else { return .success(.vm(action, profile: nil)) }
        guard let encoded = item.value, let name = encoded.removingPercentEncoding,
            name.utf8.count <= maxProfileBytes, ProfileName.isValid(name)
        else { return .failure(.badProfile) }
        return .success(.vm(action, profile: name))
    }

    /// Lowercases ASCII letters only. `lowercased()` also maps other scripts.
    private static func asciiLowercased(_ text: String) -> String {
        String(decoding: text.utf8.map { (65...90).contains($0) ? $0 + 32 : $0 }, as: UTF8.self)
    }
}
