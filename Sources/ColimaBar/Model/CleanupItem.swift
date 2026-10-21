import Foundation

/// One row of the Cleanup page. `removal` is the colima-ctl.sh action that
/// removes the item, or nil when the page offers none (an image in use, an
/// image with more than one tag, a build cache entry).
struct CleanupItem: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable { case image, volume, container, buildCache, log }

    /// The action and its arguments, for example `.imageRemove` with
    /// `["postgres:16"]`, or `.logTruncate` with the container ID and name.
    struct Removal: Equatable, Sendable {
        let action: CtlAction
        let args: [String]
    }

    /// The kind and the Docker ID or name. It is unique in the page.
    let id: String
    let kind: Kind
    /// For example "postgres:16", "pgdata", "old-api", "exec.cachemount", "api".
    let title: String
    /// For example "3 weeks ago", "compose: shop", "regular · last used 2 days ago".
    let detail: String
    /// In bytes.
    let size: Double
    let inUse: Bool
    let removal: Removal?
}
