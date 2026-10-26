import Foundation

/// What the dashboard shows about image updates for the selected profile.
struct ImageUpdateState: Equatable, Sendable {
    /// The status of each container, by container ID.
    var containers: [String: ImageUpdateStatus] = [:]
    /// The status of each image reference that a container uses, by full reference.
    var images: [String: ImageUpdateStatus] = [:]
    /// The latest registry check of these references.
    var lastCheck: Date?
    /// The references with a failed check, by failure kind.
    var failures: [ImageUpdateStatus.Failure: Int] = [:]
    /// A registry check runs now.
    var checking = false
    /// The full references with a pull of ColimaBar in progress.
    var pulling: Set<String> = []

    /// Builds the state from the facts. `configImages` maps a container ID to
    /// its `Config.Image`. `local` maps a full reference to its image.
    static func make(
        containers list: [Container], configImages: [String: String], local: [String: ImageUpdateCheck.LocalImage],
        entries: [String: ImageUpdateCache.Entry], checking: Bool = false, pulling: Set<String> = []
    ) -> ImageUpdateState {
        var state = ImageUpdateState(checking: checking, pulling: pulling)
        var refs: [String: ImageRef] = [:]
        for c in list {
            guard let configImage = configImages[c.id] else { continue }
            switch ImageUpdateCheck.reference(of: configImage) {
            case .failure(let reason): state.containers[c.id] = .skipped(reason)
            case .success(let ref):
                refs[ref.normalized] = ref
                state.containers[c.id] = ImageUpdateCheck.status(
                    ref: ref, containerImageID: c.imageID, local: local[ref.normalized],
                    remote: entries[ref.normalized])
            }
        }
        for (key, ref) in refs {
            let image = local[key]
            state.images[key] = ImageUpdateCheck.status(
                ref: ref, containerImageID: image?.id ?? "", local: image, remote: entries[key])
            guard let entry = entries[key] else { continue }
            if state.lastCheck.map({ entry.date > $0 }) ?? true { state.lastCheck = entry.date }
            if let error = entry.error { state.failures[error, default: 0] += 1 }
        }
        return state
    }

    /// The references with a newer image in the registry, sorted.
    var updateRefs: [ImageRef] {
        images.filter { $0.value.isUpdate }.keys.compactMap(ImageRef.parse).sorted { $0.normalized < $1.normalized }
    }

    /// The references that the registry can answer for: all but the skipped
    /// ones. An image that nobody pulled has no entry in a registry.
    var checkable: [ImageRef] {
        images.filter { if case .skipped = $0.value { false } else { true } }.keys.compactMap(ImageRef.parse)
    }

    var failureCount: Int { failures.values.reduce(0, +) }

    /// The status of a container for its row: nothing for a stopped container.
    func badge(for c: Container) -> ImageUpdateStatus? {
        guard c.isRunning, let s = containers[c.id] else { return nil }
        switch s {
        case .update, .recreate: return s
        default: return nil
        }
    }

    /// The update references of the containers in `list`, sorted.
    func updateRefs(of list: [Container], configImages: [String: String]) -> [ImageRef] {
        let keys = Set(list.compactMap { configImages[$0.id].flatMap(ImageRef.parse)?.normalized })
        return updateRefs.filter { keys.contains($0.normalized) }
    }

    /// The line under the setting: when the last check ran and how many
    /// images it could not check.
    func caption(now: Date) -> String {
        var parts = [lastCheck.map { "Last check \(Self.age(of: $0, now: now))" } ?? "Not checked yet"]
        if failureCount > 0 {
            parts.append("\(failureCount) image\(failureCount == 1 ? "" : "s") could not be checked")
        }
        return parts.joined(separator: " · ")
    }

    /// For example `3 h ago`.
    static func age(of date: Date, now: Date) -> String {
        let seconds = max(now.timeIntervalSince(date), 0)
        switch seconds {
        case ..<60: return "just now"
        case ..<3600: return "\(Int(seconds / 60)) min ago"
        case ..<(48 * 3600): return "\(Int(seconds / 3600)) h ago"
        default: return "\(Int(seconds / 86400)) d ago"
        }
    }
}
