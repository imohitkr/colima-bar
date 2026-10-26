import Foundation

/// What ColimaBar knows about the image of one container.
enum ImageUpdateStatus: Equatable, Sendable {
    /// The container runs the newest image that ColimaBar knows.
    case current
    /// The registry has a newer image for the tag. `digest` is the new one.
    case update(digest: String)
    /// The image of the tag is newer than the one that the container runs.
    case recreate
    /// ColimaBar does not check this image.
    case skipped(Reason)
    /// The last registry check did not give an answer.
    case failed(Failure)

    enum Reason: Error, Equatable, Sendable {
        /// The reference names a digest or an image ID. It never changes.
        case pinned
        /// The reference is not a name that ColimaBar can use.
        case unparsable
        /// Nobody pulled the image: it was built or loaded on this VM, or it is gone.
        case localOnly
    }

    /// Why a registry check gave no answer. The raw value is stored in the cache.
    enum Failure: String, Codable, Equatable, Sendable, CaseIterable {
        case unreachable, signInNeeded, notFound, rateLimited, other
    }

    var isUpdate: Bool {
        if case .update = self { return true }
        return false
    }
}
