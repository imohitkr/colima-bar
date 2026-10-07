import Foundation
import os

/// Keeps the newest log lines of containers that Docker removes when they
/// exit (`docker run --rm`, `docker compose run --rm`). Docker deletes such a
/// container and its logs right after it dies, so "View logs" on its crash
/// alert would find nothing.
///
/// While the setting is on, a `start` event makes the keeper inspect the
/// container. If `HostConfig.AutoRemove` is true, it opens one log stream and
/// keeps the newest raw log bytes in memory (`RemovedLogRing`). A `die` with a crash
/// exit code (the same rule as the crash alert) keeps the lines for
/// `keepWindow`. A clean exit, or a `destroy` without a failure, drops them.
///
/// The stream threads only copy the bytes. The main actor works only on
/// events, so many log lines cause no main-thread work. The lines are parsed
/// only when a log window opens (`saved(_:)`). The model is not observed
/// here: only `onChange` reports the set of kept containers.
@MainActor
final class RemovedLogKeeper {
    /// `saved(_:)` returns at most this many of the newest lines.
    nonisolated static let maxLines = 500
    /// At most this many containers have a buffer at the same time.
    nonisolated static let maxContainers = 50
    /// All buffers together keep at most this many raw log bytes (6.4 MB).
    /// Each container gets an equal share (`maxBytes / maxContainers`, 128 KB).
    nonisolated static let maxBytes = maxContainers * (128 << 10)
    /// How long the lines of a failed container stay after it dies.
    nonisolated static let keepWindow: TimeInterval = 5 * 60
    /// The first log request asks for this many of the newest lines.
    nonisolated static let initialTail = 100
    /// After `die`, the stream can still deliver the last lines. Then the
    /// keeper closes it, if the daemon has not closed it already.
    nonisolated static let drainGrace = Duration.seconds(2)

    /// Off drops all buffers and closes all streams.
    var isEnabled = false {
        didSet {
            guard isEnabled != oldValue else { return }
            if !isEnabled { dropAll() }
        }
    }
    /// Called with the new set of kept container ids each time it changes.
    var onChange: ((Set<String>) -> Void)?
    /// The containers whose lines `saved(_:)` returns.
    private(set) var keptIDs: Set<String> = []

    private struct Entry {
        let token: Int
        let ring: RemovedLogRing
        var handle: StreamHandle?
        /// Set when the container died with a failure.
        var keptUntil: Date?
        var oomKilled = false
        var exited = false
    }

    private var api: DockerAPI
    private let now: () -> Date
    private let containerCap: Int
    private let lineCap: Int
    private let byteCapEach: Int
    private var entries: [String: Entry] = [:]
    private var nextToken = 0
    private let log = Logger(category: "logs")

    init(
        api: DockerAPI, maxContainers: Int = RemovedLogKeeper.maxContainers,
        maxLines: Int = RemovedLogKeeper.maxLines, maxBytes: Int = RemovedLogKeeper.maxBytes,
        now: @escaping () -> Date = Date.init
    ) {
        self.api = api
        self.now = now
        containerCap = maxContainers
        lineCap = maxLines
        byteCapEach = maxBytes / max(maxContainers, 1)
    }

    /// The number of containers with a buffer, watched or kept.
    var bufferedCount: Int { entries.count }
    /// The number of open log streams.
    var openStreams: Int { entries.values.reduce(0) { $0 + ($1.handle == nil ? 0 : 1) } }

    /// Drops all buffers and uses `api` from now on. Call it on a profile switch.
    func reset(api: DockerAPI) {
        dropAll()
        self.api = api
    }

    /// Handles a container event of the selected profile.
    func event(action: String, id: String, attributes: [String: String]) {
        guard isEnabled else { return }
        switch action {
        case "start": started(id, isTestcontainer: attributes["org.testcontainers"] == "true")
        case "oom": entries[id]?.oomKilled = true
        case "die": died(id, exitCode: attributes["exitCode"])
        case "destroy": destroyed(id)
        default: break
        }
    }

    /// The kept lines of a failed container, oldest first, or nil. It
    /// parses the kept bytes now, when a log window opens.
    func saved(_ id: String) -> [LogLine]? {
        purgeExpired()
        guard let e = entries[id], e.keptUntil != nil else { return nil }
        return e.ring.lines()
    }

    /// Drops the kept buffers whose window has passed.
    func purgeExpired() {
        let t = now()
        let gone = entries.filter { $0.value.keptUntil.map { $0 <= t } ?? false }.map(\.key)
        guard !gone.isEmpty else { return }
        for id in gone { entries.removeValue(forKey: id)?.handle?.cancel() }
        publish()
    }

    // MARK: - Events

    private func started(_ id: String, isTestcontainer: Bool) {
        // ColimaBar sends no alert for testcontainers containers, so nothing
        // could open their lines.
        guard !isTestcontainer else { return }
        purgeExpired()
        if let old = entries[id] {
            guard old.keptUntil != nil else { return }  // already watched
            drop(id)
        }
        if entries.count >= containerCap, !evictOldestKept() {
            log.debug("saved logs: \(self.containerCap) containers already have a buffer; skipping one")
            return
        }
        let token = nextToken
        nextToken += 1
        let ring = RemovedLogRing(maxLines: lineCap, maxBytes: byteCapEach)
        entries[id] = Entry(token: token, ring: ring)
        let api = self.api
        Task {
            let r = await api.get("/containers/\(id)/json", timeout: 5)
            guard entries[id]?.token == token else { return }  // dropped meanwhile
            guard let r, r.ok, let info = try? JSONDecoder().decode(APIInspect.self, from: r.body),
                info.HostConfig?.AutoRemove == true
            else {
                drop(id)
                return
            }
            openStream(id, token: token, ring: ring, tty: info.Config?.Tty ?? false, api: api)
        }
    }

    private func openStream(_ id: String, token: Int, ring: RemovedLogRing, tty: Bool, api: DockerAPI) {
        ring.setTTY(tty)
        let q = "follow=1&stdout=1&stderr=1&timestamps=1&tail=\(Self.initialTail)"
        let h = api.streamRaw(
            "/containers/\(id)/logs?\(q)",
            onData: { ring.feed($0) },  // on the reader thread, no hop to main
            onEnd: { [weak self] h in
                Task { @MainActor in self?.streamEnded(id, token: token, handle: h) }
            })
        entries[id]?.handle = h
        // The container died while the inspect call ran.
        if entries[id]?.exited == true { closeLater(id, h) }
    }

    private func streamEnded(_ id: String, token: Int, handle: StreamHandle) {
        guard entries[id]?.handle === handle else { return }
        entries[id]?.handle = nil
        guard entries[id]?.exited == false else { return }
        // The stream ended before a `die` event, for example after a lost
        // events connection. Do not hold the slot forever.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.keepWindow))
            guard let self, let e = self.entries[id], e.token == token, !e.exited else { return }
            self.drop(id)
        }
    }

    private func died(_ id: String, exitCode: String?) {
        guard var e = entries[id] else { return }
        guard e.oomKilled || ColimaModel.isCrashExit(exitCode) else {
            drop(id)
            return
        }
        e.exited = true
        e.keptUntil = now().addingTimeInterval(Self.keepWindow)
        entries[id] = e
        if let h = e.handle { closeLater(id, h) }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.keepWindow))
            self?.purgeExpired()
        }
        publish()
    }

    private func destroyed(_ id: String) {
        guard let e = entries[id], e.keptUntil == nil else { return }
        drop(id)
    }

    /// Closes the stream after `drainGrace`. The daemon usually closes it
    /// first, after it sent the last lines.
    private func closeLater(_ id: String, _ h: StreamHandle) {
        Task { [weak self] in
            try? await Task.sleep(for: Self.drainGrace)
            guard let self, self.entries[id]?.handle === h else { return }
            h.cancel()  // a cancelled stream calls no onEnd
            self.entries[id]?.handle = nil
        }
    }

    // MARK: - Helpers

    /// Drops the kept buffer that expires first. False if none is kept.
    private func evictOldestKept() -> Bool {
        let kept = entries.compactMap { id, e in e.keptUntil.map { (id, $0) } }
        guard let oldest = kept.min(by: { $0.1 < $1.1 }) else { return false }
        drop(oldest.0)
        return true
    }

    private func drop(_ id: String) {
        entries.removeValue(forKey: id)?.handle?.cancel()
        publish()
    }

    private func dropAll() {
        for e in entries.values { e.handle?.cancel() }
        entries = [:]
        publish()
    }

    /// Reports the kept set only when it changed.
    private func publish() {
        let ids = Set(entries.compactMap { $0.value.keptUntil == nil ? nil : $0.key })
        guard ids != keptIDs else { return }
        keptIDs = ids
        onChange?(ids)
    }
}
