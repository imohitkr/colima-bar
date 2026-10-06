import Foundation

/// Release pages that ColimaBar opens. Only a release page of this repo on
/// github.com is used.
enum ReleaseLink {
    static let latest = URL(string: "https://github.com/imohitkr/colima-bar/releases/latest")!

    /// The release page of `tag`. ColimaBar builds the URL itself and does
    /// not use a URL from the GitHub response. A tag that is not exactly
    /// vX.Y.Z (or X.Y.Z) gives the latest release page.
    static func page(tag: String) -> URL {
        guard isReleaseTag(tag),
            let u = URL(string: "https://github.com/imohitkr/colima-bar/releases/tag/\(tag)")
        else { return latest }
        return u
    }

    /// An optional "v" and three dot-separated groups of ASCII digits.
    static func isReleaseTag(_ tag: String) -> Bool {
        let core = tag.hasPrefix("v") ? tag.dropFirst() : Substring(tag)
        let parts = core.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 3
            && parts.allSatisfy { p in
                !p.isEmpty && p.count <= 9 && p.utf8.allSatisfy { $0 >= 0x30 && $0 <= 0x39 }
            }
    }

    static func isTrusted(_ url: URL) -> Bool {
        guard let c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
        // "%2e%2e" is ".." to a browser: check each segment in decoded form.
        // A segment with a broken percent escape is rejected too.
        let segments = c.percentEncodedPath.split(separator: "/", omittingEmptySubsequences: false)
        let badSegment = segments.contains { s in
            guard let d = String(s).removingPercentEncoding else { return true }
            return d == "." || d == ".." || d.contains("/") || d.contains("\\")
        }
        return c.scheme?.lowercased() == "https"
            && c.host?.lowercased() == "github.com"
            && c.user == nil && c.password == nil && c.port == nil
            && c.percentEncodedPath.hasPrefix("/imohitkr/colima-bar/releases/")
            && !badSegment
    }

    /// `url` if it is trusted, else the latest release page.
    static func page(_ url: URL?) -> URL {
        guard let url, isTrusted(url) else { return latest }
        return url
    }
}
