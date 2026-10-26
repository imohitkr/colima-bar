import Foundation

/// The rules that turn the facts about a container and its image into an
/// `ImageUpdateStatus`. The functions are pure. `ImageUpdateRunner` reads the
/// facts from the daemon and the registry.
enum ImageUpdateCheck {
    /// The part of `GET /images/{ref}/json` that the rules read.
    struct LocalImage: Equatable, Sendable {
        let id: String
        let repoDigests: [String]
        let os: String?
        let architecture: String?
        let variant: String?

        init(_ detail: APIImageDetail) {
            id = detail.Id ?? ""
            repoDigests = detail.RepoDigests ?? []
            os = detail.Os
            architecture = detail.Architecture
            variant = detail.Variant
        }

        init(id: String, repoDigests: [String], os: String? = nil, architecture: String? = nil, variant: String? = nil)
        {
            self.id = id
            self.repoDigests = repoDigests
            self.os = os
            self.architecture = architecture
            self.variant = variant
        }
    }

    /// The reference of a container as `Config.Image` has it: a usable
    /// reference, or the reason to skip the container.
    static func reference(of configImage: String?) -> Result<ImageRef, ImageUpdateStatus.Reason> {
        guard let text = configImage, !text.isEmpty else { return .failure(.unparsable) }
        if let ref = ImageRef.parse(text) { return .success(ref) }
        return .failure(text.contains("@") || text.hasPrefix("sha256:") ? .pinned : .unparsable)
    }

    /// The digests in `repoDigests` that belong to the repository of `ref`.
    /// A digest of another repository, for example after a `docker tag`, does
    /// not say anything about this tag.
    static func digests(in repoDigests: [String], of ref: ImageRef) -> [String] {
        repoDigests.compactMap { entry in
            ImageRef.repoDigest(entry).flatMap { $0.repository == ref.repository ? $0.digest : nil }
        }
    }

    /// The status of one container.
    /// - `containerImageID`: the `ImageID` of the container. Empty when the daemon gave none.
    /// - `local`: the image that the tag names now, or nil if the daemon has no such image.
    /// - `remote`: the last registry answer for the tag, or nil if there is none.
    static func status(
        ref: ImageRef, containerImageID: String, local: LocalImage?, remote: ImageUpdateCache.Entry?
    ) -> ImageUpdateStatus {
        guard let local else { return .skipped(.localOnly) }
        let own = digests(in: local.repoDigests, of: ref)
        guard !own.isEmpty else { return .skipped(.localOnly) }
        // A pull that left the image as it was ends the update: the registry only republished the index.
        if let digest = remote?.digest, remote?.pulled != true, !own.contains(digest) {
            return .update(digest: digest)
        }
        if !containerImageID.isEmpty, containerImageID != local.id { return .recreate }
        if let error = remote?.error { return .failed(error) }
        return .current
    }

    /// The failure kind of a reply of the daemon. `status` is nil when the
    /// daemon gave no reply. `message` is the text of the reply.
    static func classify(status: Int?, message: String?) -> ImageUpdateStatus.Failure {
        guard let status else { return .unreachable }
        let text = (message ?? "").lowercased()
        if status == 401 || status == 403 || text.contains("unauthorized") || text.contains("denied") {
            return .signInNeeded
        }
        if status == 404 || text.contains("manifest unknown") { return .notFound }
        if status == 429 || text.contains("toomanyrequests") || text.contains("too many requests") {
            return .rateLimited
        }
        if status >= 500, ["dial tcp", "i/o timeout", "no such host"].contains(where: text.contains) {
            return .unreachable
        }
        return .other
    }

    /// The most characters of a registry message that ColimaBar shows.
    static let messageLimit = 120

    /// The message cut to `messageLimit` characters, on one line.
    static func shortened(_ message: String) -> String {
        let line = message.split(whereSeparator: \.isNewline).joined(separator: " ")
        return line.count <= messageLimit ? line : String(line.prefix(messageLimit - 1)) + "…"
    }

    /// The `platform` value for a pull, or nil. An image that is not for the
    /// architecture of the VM (an amd64 image under Rosetta) needs it, else
    /// the daemon pulls the image of its own architecture.
    static func platform(of image: LocalImage, hostArchitecture: String?) -> String? {
        guard let os = image.os, let arch = image.architecture, !os.isEmpty, !arch.isEmpty else { return nil }
        guard let host = hostArchitecture.map(normalizedArchitecture), host != normalizedArchitecture(arch) else {
            return nil
        }
        guard let variant = image.variant, !variant.isEmpty else { return "\(os)/\(arch)" }
        return "\(os)/\(arch)/\(variant)"
    }

    /// The names of `uname` and of the Docker API for the same CPU.
    static func normalizedArchitecture(_ arch: String) -> String {
        switch arch {
        case "aarch64": "arm64"
        case "x86_64": "amd64"
        default: arch
        }
    }
}
