import Foundation

extension Optional where Wrapped == Bool {
    var orFalse: Bool { self ?? false }
}

/// Typed-ish UserDefaults access that distinguishes "unset" from false/0.
enum Defaults {
    static func string(_ k: String) -> String? { UserDefaults.standard.string(forKey: k) }
    static func bool(_ k: String) -> Bool? { UserDefaults.standard.object(forKey: k) as? Bool }
    static func int(_ k: String) -> Int? { UserDefaults.standard.object(forKey: k) as? Int }
    static func set(_ v: Any, _ k: String) { UserDefaults.standard.set(v, forKey: k) }
}
