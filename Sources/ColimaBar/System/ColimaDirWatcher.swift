import Foundation

/// Watches the directories that change when any Colima profile starts,
/// stops, appears or goes away: the Colima config folder (`Paths.colimaDir`),
/// each profile directory, Lima's folder (`Paths.limaDir`) and each Lima
/// instance directory. Lima creates
/// and removes ha.sock and ha.pid in the instance directory. Changes that
/// come close together call `onChange` once. It is called at most once per
/// `minGap`, and a change is never dropped, only delayed.
@MainActor
final class ColimaDirWatcher {
    private let root: String
    private let lima: String
    private let debounce: Duration
    private let minGap: Duration
    private let onChange: @MainActor () -> Void
    private var sources: [String: DispatchSourceFileSystemObject] = [:]
    private var pending: Task<Void, Never>?
    private var lastFire: ContinuousClock.Instant?

    /// `root` is the Colima config folder, `lima` Lima's folder. `lima` is
    /// nil for the `_lima` folder of `root`.
    init(
        root: String, lima: String? = nil, debounce: Duration = .seconds(2),
        minGap: Duration = .seconds(10), onChange: @escaping @MainActor () -> Void
    ) {
        self.root = root
        self.lima = lima ?? "\(root)/_lima"
        self.debounce = debounce
        self.minGap = minGap
        self.onChange = onChange
        rearm()
    }

    deinit {
        for s in sources.values { s.cancel() }
    }

    var watched: Set<String> { Set(sources.keys) }

    /// The directories to watch that exist now. Names that start with "_"
    /// or "." are Colima's and Lima's own stores, not profiles or instances.
    /// `lima` is nil for the `_lima` folder of `root`.
    nonisolated static func watchPaths(root: String, lima: String? = nil) -> Set<String> {
        let fm = FileManager.default
        func isDir(_ p: String) -> Bool {
            var d: ObjCBool = false
            return fm.fileExists(atPath: p, isDirectory: &d) && d.boolValue
        }
        func children(_ dir: String) -> [String] {
            ((try? fm.contentsOfDirectory(atPath: dir)) ?? [])
                .filter { !$0.hasPrefix("_") && !$0.hasPrefix(".") }
                .map { "\(dir)/\($0)" }
                .filter(isDir)
        }
        var out: Set<String> = []
        if isDir(root) {
            out.insert(root)
            out.formUnion(children(root))
        }
        let lima = lima ?? "\(root)/_lima"
        if isDir(lima) {
            out.insert(lima)
            out.formUnion(children(lima))
        }
        return out
    }

    /// Starts watching new directories and stops watching removed ones.
    func rearm() {
        let want = Self.watchPaths(root: root, lima: lima)
        for (path, s) in sources where !want.contains(path) {
            s.cancel()
            sources[path] = nil
        }
        for path in want where sources[path] == nil {
            let fd = open(path, O_EVTONLY)
            guard fd >= 0 else { continue }
            let s = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd, eventMask: [.write, .delete, .rename],
                queue: .main)
            s.setEventHandler { [weak self, weak s] in
                guard let s else { return }
                let gone = !s.data.isDisjoint(with: [.delete, .rename])
                MainActor.assumeIsolated { self?.changed(path, gone: gone) }
            }
            s.setCancelHandler { close(fd) }
            s.resume()
            sources[path] = s
        }
    }

    private func changed(_ path: String, gone: Bool) {
        // The descriptor now points at a removed or moved directory. Drop it,
        // so the next rearm() opens the path again if it exists.
        if gone, let s = sources.removeValue(forKey: path) { s.cancel() }
        // A callback is already scheduled: it also covers this change.
        guard pending == nil else { return }
        let now = ContinuousClock.now
        var at = now + debounce
        if let lastFire, lastFire + minGap > at { at = lastFire + minGap }
        pending = Task { [weak self] in
            try? await Task.sleep(until: at, clock: .continuous)
            guard let self else { return }
            self.pending = nil
            self.lastFire = .now
            self.rearm()
            self.onChange()
        }
    }
}
