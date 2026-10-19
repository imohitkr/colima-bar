import Foundation

/// The loop of a backup: one volume, or each named volume (Back Up All). It
/// runs the volumes one after the other through one `VolumeBackupRunner`, and
/// returns what happened to each. `ColimaModel` turns the summary into a
/// notification.
enum VolumeBackupBatch {
    struct Item: Equatable, Sendable {
        let name: String
        /// The size that Docker reports for the volume, for the progress bar.
        let size: Double
        /// The full path of the file to write.
        let destination: String
    }

    struct Done: Equatable {
        let name: String
        let file: String
        let bytes: Int64
    }

    struct Failed: Equatable {
        let name: String
        let reason: String
        /// A file existed, so the backup removed it.
        let removedFile: Bool
    }

    struct Summary: Equatable {
        var done: [Done] = []
        var failed: [Failed] = []
        /// The reason that no volume could start (the helper image).
        var prepareFailure: String?
        var cancelled = false
        /// The first volume began.
        var started = false
        /// A cancel left no file when this is false.
        var cancelRemovedFile = false
        /// The loop stopped at the first full disk.
        var diskFull = false
    }

    /// Backs up the volumes in order. A cancel ends the loop. A full disk
    /// ends it too, because each later volume would fail the same way.
    /// `willStart` runs before each volume, with its place in the loop.
    /// `replace` is true only for the single backup that the save panel confirmed.
    @MainActor
    static func run(
        runner: VolumeBackupRunner, items: [Item], replace: Bool, app: String,
        willStart: @MainActor (_ index: Int, _ item: Item) -> Void,
        onProgress: @escaping @Sendable (Int64) -> Void
    ) async -> Summary {
        var summary = Summary()
        if let f = await runner.prepare() {
            if f.cancelled { summary.cancelled = true } else { summary.prepareFailure = f.reason }
            return summary
        }
        for (i, item) in items.enumerated() {
            if runner.isCancelled {
                summary.cancelled = true
                break
            }
            summary.started = true
            willStart(i, item)
            switch await backUpOne(item, replace: replace, app: app, runner: runner, onProgress: onProgress) {
            case .success(let bytes):
                summary.done.append(
                    Done(name: item.name, file: (item.destination as NSString).lastPathComponent, bytes: bytes))
            case .failure(let f) where f.cancelled:
                summary.cancelled = true
                summary.cancelRemovedFile = f.wroteFile
            case .failure(let f):
                summary.failed.append(Failed(name: item.name, reason: f.reason, removedFile: f.wroteFile))
                if f.isDiskFull {
                    summary.diskFull = true
                }
            }
            if summary.cancelled || summary.diskFull { break }
        }
        return summary
    }

    private static func backUpOne(
        _ item: Item, replace: Bool, app: String, runner: VolumeBackupRunner,
        onProgress: @escaping @Sendable (Int64) -> Void
    ) async -> Result<Int64, VolumeBackupRunner.Failure> {
        let info: APIVolume
        switch await runner.lookup(item.name) {
        case .found(let v): info = v
        case .missing: return .failure(.text("The volume does not exist any more."))
        case .failed(let f): return .failure(f)
        }
        let meta = VolumeBackupMeta(
            name: item.name, driver: info.Driver ?? "local", labels: info.Labels ?? [:],
            created: info.CreatedAt ?? "", app: app)
        return await runner.backUp(
            volume: item.name, meta: meta, to: item.destination, replace: replace, onProgress: onProgress)
    }
}
