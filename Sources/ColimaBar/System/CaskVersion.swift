import Foundation

/// The version in the Homebrew cask of ColimaBar. The tap updates the cask a
/// few minutes after a release, so for a short time the newest release is
/// not in the cask. `brew upgrade` cannot install it then, so a Homebrew
/// install offers only a version that the cask has.
enum CaskVersion {
    static var url: URL {
        #if COLIMABAR_UPDATE_TEST
            if let base = UpdateTestHooks.base { return base.appendingPathComponent("cask/colima-bar.rb") }
        #endif
        return URL(string: "https://raw.githubusercontent.com/imohitkr/homebrew-tap/main/Casks/colima-bar.rb")!
    }

    /// The largest cask file that ColimaBar reads.
    static let maxBytes = 64 * 1024

    /// The value of the line `version "X.Y.Z"`, or nil if the cask has no
    /// such line or more than one.
    static func parse(_ text: String) -> String? {
        let prefix = "version \""
        let found = text.split(separator: "\n", omittingEmptySubsequences: false).compactMap { line -> String? in
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.count > prefix.count, t.hasPrefix(prefix), t.hasSuffix("\"") else { return nil }
            let value = String(t.dropFirst(prefix.count).dropLast())
            return !value.hasPrefix("v") && ReleaseLink.isReleaseTag(value) ? value : nil
        }
        return found.count == 1 ? found[0] : nil
    }
}
