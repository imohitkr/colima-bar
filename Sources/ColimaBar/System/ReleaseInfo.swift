import Foundation

/// The newest release as ColimaBar reads it from the GitHub API.
struct ReleaseInfo: Equatable, Sendable {
    /// The file that an in-app update installs.
    struct Asset: Equatable, Sendable {
        let size: Int
        /// 64 lowercase hex digits.
        let sha256: String
    }

    let version: String  // without the leading "v"
    let tag: String
    /// The release page. ColimaBar builds it from the tag.
    let page: URL
    /// The zip, only when an in-app update can install it: the release is
    /// immutable, the asset is named `ColimaBar.zip`, and it has a valid
    /// size and SHA-256 digest.
    let zip: Asset?
    /// The macOS that the release needs, from the line `Requires macOS 15.0
    /// or later.` in its body. nil if the body has no such line.
    var minimumMacOS: String? = nil

    static let zipName = "ColimaBar.zip"

    /// Reads the answer of `releases/latest`. Returns nil for data that is
    /// not a release, and for a draft or a prerelease. It does not use
    /// `html_url` or `browser_download_url`: ColimaBar builds both URLs
    /// from the tag.
    static func parse(_ data: Data) -> ReleaseInfo? {
        guard let j = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            let tag = j["tag_name"] as? String,
            (j["draft"] as? Bool) != true, (j["prerelease"] as? Bool) != true
        else { return nil }
        var zip: Asset?
        if (j["immutable"] as? Bool) == true, ReleaseLink.isReleaseTag(tag),
            let assets = j["assets"] as? [[String: Any]]
        {
            let candidates = assets.filter { ($0["name"] as? String) == zipName }
            // Two files with the same name are not a release that ColimaBar knows.
            if candidates.count == 1, let size = candidates[0]["size"] as? Int,
                size > 0, size <= UpdatePolicy.maxZipBytes,
                let digest = (candidates[0]["digest"] as? String).flatMap(ReleaseDigest.parse)
            {
                zip = Asset(size: size, sha256: digest)
            }
        }
        return ReleaseInfo(
            version: Version.strip(tag), tag: tag, page: ReleaseLink.page(tag: tag), zip: zip,
            minimumMacOS: (j["body"] as? String).flatMap(UpdateVerifier.requiredMacOS(inReleaseBody:)).map(
                UpdateVerifier.describeMinimum))
    }
}
