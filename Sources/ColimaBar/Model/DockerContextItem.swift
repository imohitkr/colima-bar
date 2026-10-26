import Foundation

/// One docker context that the context menu offers. `DockerContextStore`
/// reads it from the context folder, with no docker process.
struct DockerContextItem: Equatable, Sendable, Identifiable {
    enum Kind: Equatable, Sendable {
        /// The context `colimabar`: the selected profile, with auto-start.
        case own
        /// The context `colimabar-PROFILE`.
        case ownProfile(String)
        /// A context that Colima made (`colima`, `colima-PROFILE`).
        case colima(String)
        case `default`
        case other
    }

    let name: String
    let description: String
    let endpoint: String

    var id: String { name }
    var kind: Kind { Self.kind(of: name) }

    /// A pick of a context of this kind is a choice that ColimaBar keeps and
    /// restores after `colima start`.
    var isForeign: Bool { kind == .default || kind == .other }

    static func kind(of name: String) -> Kind {
        if name == Routing.contextName { return .own }
        if name.hasPrefix(ProfileContexts.prefix), name.count > ProfileContexts.prefix.count {
            return .ownProfile(String(name.dropFirst(ProfileContexts.prefix.count)))
        }
        if name == "default" { return .default }
        if let profile = Routing.colimaProfile(name) { return .colima(profile) }
        return .other
    }
}
