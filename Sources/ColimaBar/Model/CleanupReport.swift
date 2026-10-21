import Foundation

/// The sections of the Cleanup page. `make(from:)` builds them from the
/// `/system/df` answer that the Images and Volumes tabs already use, so the
/// page needs no new Docker request. All functions are pure.
struct CleanupReport: Equatable, Sendable {
    /// The page shows at most this many rows in each section.
    static let rowLimit = 10
    static let cacheRowLimit = 5
    /// The longest part of a build cache description that a row shows.
    static let descriptionLimit = 60

    struct Section: Equatable, Sendable {
        /// The largest rows, at most the limit.
        var items: [CleanupItem] = []
        /// The rows over the limit and their size.
        var hiddenCount = 0
        var hiddenSize: Double = 0
        /// The size of all rows of the section that the section can free.
        var reclaimable: Double = 0

        var count: Int { items.count + hiddenCount }
        var isEmpty: Bool { count == 0 }
        /// The size of all rows, also of those over the limit.
        var totalSize: Double { items.reduce(hiddenSize) { $0 + $1.size } }

        /// The largest first. The title breaks a tie, so equal sizes never
        /// swap rows between two refreshes.
        init(all: [CleanupItem] = [], limit: Int = CleanupReport.rowLimit, reclaimable: Double = 0) {
            let sorted = all.sorted { ($1.size, $0.title, $0.id) < ($0.size, $1.title, $1.id) }
            items = Array(sorted.prefix(limit))
            let hidden = sorted.dropFirst(limit)
            hiddenCount = hidden.count
            hiddenSize = hidden.reduce(0) { $0 + $1.size }
            self.reclaimable = reclaimable
        }
    }

    /// All images, largest first. An image in use has no removal.
    var images = Section()
    /// Only volumes that no container uses.
    var volumes = Section()
    /// Only containers that do not run. ColimaBar's helper containers are left out.
    var containers = Section()
    /// The largest entries. Reclaimable counts those that are not in use and not shared.
    var buildCache = Section()
    /// The name of each container by full ID, from the df container list (all
    /// states, without ColimaBar's helper containers).
    var containerNames: [String: String] = [:]

    /// The states of a container that docker removes safely. A paused or
    /// restarting container is not stopped.
    static let stoppedStates: Set<String> = ["exited", "created", "dead"]

    static let empty = CleanupReport()
    var isEmpty: Bool { self == .empty }

    /// The space that the four Docker sections can free.
    var reclaimable: Double {
        images.reclaimable + volumes.reclaimable + containers.reclaimable + buildCache.reclaimable
    }

    static func make(from df: APIDF) -> CleanupReport {
        let imgs = df.Images ?? []
        let ctrs = df.Containers ?? []
        let vols = df.Volumes ?? []
        let cache = df.BuildCache ?? []
        var report = CleanupReport()

        report.images = Section(
            all: imgs.map(imageItem),
            reclaimable: sum(imgs.filter { $0.Containers == 0 }) { $0.Size - ($0.SharedSize ?? 0) })

        // Docker gives no UsageData when it did not measure the volume: such a
        // volume may be in use, so it is not listed.
        let unusedVols = vols.filter { $0.UsageData.map { $0.RefCount == 0 } ?? false }
        report.volumes = Section(
            all: unusedVols.map(volumeItem), reclaimable: sum(unusedVols) { $0.UsageData?.Size ?? 0 })

        // The rows and the reclaimable size use the same containers: those
        // that cannot run again, with a name, without ColimaBar's helpers.
        let stopped = ctrs.filter { Self.stoppedStates.contains($0.State) && !isHelper($0) && name(of: $0) != nil }
        report.containers = Section(
            all: stopped.compactMap(containerItem), reclaimable: sum(stopped) { $0.SizeRw ?? 0 })

        report.buildCache = Section(
            all: cache.enumerated().map { cacheItem($1, index: $0) }, limit: cacheRowLimit,
            reclaimable: sum(cache.filter { !$0.InUse && !$0.Shared }) { $0.Size })

        for c in ctrs where !isHelper(c) {
            if let id = c.Id, let name = name(of: c) { report.containerNames[id] = name }
        }
        return report
    }

    /// The log rows: the largest first, at most `rowLimit`. A name comes from
    /// `containerNames`, else it is the 12-character short ID. An ID that the
    /// df list does not know is left out: the container is gone.
    func logItems(_ sizes: [String: Int64]) -> Section {
        let rows = sizes.compactMap { id, size -> CleanupItem? in
            guard let name = containerNames[id] else { return nil }
            let shown = name.isEmpty ? String(id.prefix(12)) : name
            return CleanupItem(
                id: "log:\(id)", kind: .log, title: shown, detail: "", size: Double(max(size, 0)), inUse: false,
                removal: .init(action: .logTruncate, args: [id, shown]))
        }
        return Section(all: rows, reclaimable: 0)
    }

    // MARK: - Rows

    private static func sum<T>(_ xs: [T], _ f: (T) -> Int64) -> Double {
        Double(xs.reduce(0) { $0 + max(f($1), 0) })
    }

    private static func imageItem(_ i: APIDF.Image) -> CleanupItem {
        let tags = (i.RepoTags ?? []).filter { $0 != "<none>:<none>" }
        let inUse = i.Containers > 0
        let title: String
        let removal: CleanupItem.Removal?
        if let first = tags.first {
            title = tags.count > 1 ? "\(first) +\(tags.count - 1) \(tags.count == 2 ? "tag" : "tags")" : first
            removal = inUse || tags.count > 1 ? nil : .init(action: .imageRemove, args: [first])
        } else {
            title = "<none>"
            let short = String(i.Id.replacingOccurrences(of: "sha256:", with: "").prefix(12))
            removal = inUse ? nil : .init(action: .imageRemove, args: [short])
        }
        let created = Date(timeIntervalSince1970: TimeInterval(i.Created))
        return CleanupItem(
            id: "image:\(i.Id)", kind: .image, title: title,
            detail: created.formatted(.relative(presentation: .named)), size: Double(max(i.Size, 0)),
            inUse: inUse, removal: removal)
    }

    private static func volumeItem(_ v: APIDF.Volume) -> CleanupItem {
        let detail: String
        if let project = v.Labels?["com.docker.compose.project"] {
            detail = "compose: \(project)"
        } else if v.Labels?["com.docker.volume.anonymous"] != nil {
            detail = "anonymous"
        } else {
            detail = ""
        }
        return CleanupItem(
            id: "volume:\(v.Name)", kind: .volume, title: v.Name, detail: detail,
            size: Double(max(v.UsageData?.Size ?? 0, 0)), inUse: false,
            removal: .init(action: .volumeRemove, args: [v.Name]))
    }

    private static func name(of c: APIDF.Ctr) -> String? {
        guard let first = c.Names?.first else { return nil }
        return first.hasPrefix("/") ? String(first.dropFirst()) : first
    }

    private static func isHelper(_ c: APIDF.Ctr) -> Bool {
        ColimaModel.isInternalContainer(name: name(of: c), attributes: c.Labels ?? [:])
    }

    private static func containerItem(_ c: APIDF.Ctr) -> CleanupItem? {
        guard let name = name(of: c) else { return nil }
        return CleanupItem(
            id: "container:\(c.Id ?? name)", kind: .container, title: name, detail: c.Image ?? c.State,
            size: Double(max(c.SizeRw ?? 0, 0)), inUse: false,
            removal: .init(action: .containerRemove, args: [name]))
    }

    /// The description is the build step, so it is the title. The type goes in the detail.
    private static func cacheItem(_ c: APIDF.Cache, index: Int) -> CleanupItem {
        let kind = cacheKind(c.Type)
        let title = c.Description.flatMap { $0.isEmpty ? nil : String($0.prefix(descriptionLimit)) } ?? kind
        var parts = [kind]
        if let used = c.LastUsedAt, let date = parseDate(used) {
            parts.append("last used \(date.formatted(.relative(presentation: .named)))")
        }
        return CleanupItem(
            id: "cache:\(c.ID ?? String(index))", kind: .buildCache, title: title,
            detail: parts.joined(separator: " · "), size: Double(max(c.Size, 0)), inUse: c.InUse, removal: nil)
    }

    /// Plain names for the BuildKit record types.
    static func cacheKind(_ type: String?) -> String {
        switch type {
        case "regular": "Layer"
        case "source.local": "Build context"
        case "exec.cachemount": "Cache mount"
        case "source.git.checkout": "Git checkout"
        case let t?: t
        case nil: "Cache"
        }
    }

    /// Docker writes `LastUsedAt` in ISO 8601 with fractions of a second.
    private static func parseDate(_ text: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: text) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: text)
    }
}
