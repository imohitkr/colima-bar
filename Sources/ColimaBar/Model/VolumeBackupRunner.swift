import Darwin
import Foundation
import os

/// The Docker calls of a volume backup or restore, in order. It talks to the
/// socket of one profile only (the `DockerAPI` of the caller), so it never
/// starts the VM.
///
/// A helper container holds the volume. It is created and never started: the
/// archive calls work on a created container. The runner removes the helper
/// after each operation, with `force` and without `v=1`, so the volume stays.
///
/// One transfer at a time uses a runner. `cancel()` can come from any thread.
/// `@unchecked Sendable`: `lock` guards every mutable property.
final class VolumeBackupRunner: @unchecked Sendable {
    struct Failure: Error, Equatable {
        let reason: String
        var cancelled = false
        /// A file existed at some time during the operation, so a failure removed it.
        var wroteFile = false
        static let cancel = Failure(reason: "cancelled", cancelled: true)
        static let diskFull = Failure(reason: "The disk of your Mac is full.")
        static func text(_ reason: String) -> Failure { Failure(reason: reason) }
        var isDiskFull: Bool { reason == Self.diskFull.reason }
    }

    /// A file with this name exists, so nothing was written.
    static let exists = Failure(reason: "A file with this name exists.")

    enum Lookup {
        case found(APIVolume)
        case missing
        case failed(Failure)
    }

    private static let log = Logger(category: "volume-backup")
    private let api: DockerAPI
    private let newSuffix: @Sendable () -> String
    private let lock = NSLock()
    private var cancelled = false
    private var stopped = false
    private var current: StreamHandle?
    private var gate: OneShot?
    private var leftHelper = false

    init(api: DockerAPI, newSuffix: @escaping @Sendable () -> String = VolumeBackupRunner.randomSuffix) {
        self.api = api
        self.newSuffix = newSuffix
    }

    static func randomSuffix() -> String {
        String(format: "%08x", UInt32.random(in: 0...UInt32.max))
    }

    var isCancelled: Bool { lock.withLock { cancelled } }

    /// True if Docker could not remove a helper container. It can still hold
    /// a volume, so a sweep must run again.
    var leftHelperContainer: Bool { lock.withLock { leftHelper } }

    /// Stops the transfer that runs now. The operation ends with `Failure.cancel`.
    func cancel() {
        let (handle, gate) = lock.withLock {
            cancelled = true
            return (current, self.gate)
        }
        handle?.cancel()
        gate?.fire()
    }

    // MARK: - Image

    /// Loads the helper image, unless the daemon has it.
    func prepare() async -> Failure? {
        if isCancelled { return .cancel }
        if let r = await api.get("/images/\(HelperImage.tag)/json"), r.ok { return nil }
        var arch: String?
        if let r = await api.get("/info", timeout: 10), r.ok {
            arch = (try? JSONDecoder().decode(APIInfo.self, from: r.body))?.Architecture
        }
        let tar = HelperImage.archive(arch: HelperImage.architecture(info: arch))
        guard
            let r = await api.request(
                "POST", "/images/load?quiet=1", headers: ["Content-Type": "application/x-tar"], body: tar,
                timeout: 60)
        else { return .text("Docker did not answer.") }
        guard r.ok else { return .text("Docker cannot load the helper image: \(Self.reason(r)).") }
        if String(decoding: r.body, as: UTF8.self).contains("\"error\"") {
            return .text("Docker cannot load the helper image.")
        }
        return nil
    }

    /// Removes the helper image. A container that still uses it gives 409:
    /// that is no error.
    func release() async {
        _ = await api.request("DELETE", "/images/\(HelperImage.tag)")
    }

    /// Removes the helper containers that an earlier run left (both labels),
    /// then the helper image. Nothing else is touched. `isBusy` tells that a
    /// transfer runs: it is asked before each removal, and then the sweep stops.
    static func sweepLeftovers(api: DockerAPI, isBusy: @Sendable () async -> Bool = { false }) async {
        let path = "/containers/json?all=1&filters=" + DockerAPI.percentEncoded(HelperImage.labelFilter)
        if let r = await api.get(path), r.ok,
            let list = try? JSONDecoder().decode([APIContainer].self, from: r.body)
        {
            for c in list where ColimaModel.isInspectable(id: c.Id) {
                if await isBusy() { return }
                _ = await api.request("DELETE", "/containers/\(c.Id)?force=1")
            }
        }
        if await isBusy() { return }
        _ = await api.request("DELETE", "/images/\(HelperImage.tag)")
    }

    // MARK: - Volumes

    func lookup(_ name: String) async -> Lookup {
        guard let r = await api.get("/volumes/\(DockerAPI.percentEncoded(name))") else {
            return .failed(.text("Docker did not answer."))
        }
        if r.status == 404 { return .missing }
        guard r.ok, let v = try? JSONDecoder().decode(APIVolume.self, from: r.body) else {
            return .failed(.text("Docker cannot read the volume: \(Self.reason(r))."))
        }
        return .found(v)
    }

    /// The names of the containers that use the volume. A helper container
    /// is not one of them. With `runningOnly`, stopped containers do not count.
    func users(of volume: String, runningOnly: Bool) async -> [String]? {
        var filters: [String: [String]] = ["volume": [volume]]
        if runningOnly { filters["status"] = ["running"] }
        let data = (try? JSONSerialization.data(withJSONObject: filters, options: [.sortedKeys])) ?? Data()
        let query =
            (runningOnly ? "" : "all=1&") + "filters=" + DockerAPI.percentEncoded(String(decoding: data, as: UTF8.self))
        guard let r = await api.get("/containers/json?\(query)"), r.ok,
            let list = try? JSONDecoder().decode([APIContainer].self, from: r.body)
        else { return nil }
        return list.filter { !HelperImage.isHelper(labels: $0.Labels) }
            .map { $0.Names.first.map { String($0.drop { $0 == "/" }) } ?? String($0.Id.prefix(12)) }
            .sorted()
    }

    func createVolume(_ name: String, labels: [String: String]) async -> Failure? {
        let body: [String: Any] = ["Name": name, "Driver": "local", "Labels": labels]
        let json = (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
        guard let r = await api.post("/volumes/create", json: json) else { return .text("Docker did not answer.") }
        return r.ok ? nil : .text("Docker cannot create the volume: \(Self.reason(r)).")
    }

    func deleteVolume(_ name: String) async -> Failure? {
        guard let r = await api.request("DELETE", "/volumes/\(DockerAPI.percentEncoded(name))") else {
            return .text("Docker did not answer.")
        }
        return r.ok ? nil : .text("Docker cannot delete the volume: \(Self.reason(r)).")
    }

    /// True if the volume has no file. It reads the start of the archive of
    /// the volume (a read-only mount) and stops at the first entry besides `v/`.
    func isEmpty(volume: String) async -> Result<Bool, Failure> {
        await withHelper(volume: volume, readOnly: true) { id in
            let sink = ArchiveSink(writer: nil, stopOnContent: true, onProgress: { _ in })
            let end = await self.stream(id: id, sink: sink)
            if self.isCancelled { return .failure(.cancel) }
            if sink.sawContent { return .success(false) }
            if let f = sink.failure { return .failure(f) }
            if let f = Self.streamFailure(end) { return .failure(f) }
            return sink.isComplete ? .success(true) : .failure(.text("The archive from Docker is not complete."))
        }
    }

    // MARK: - Backup

    /// Streams the archive of the volume into a private file. The ColimaBar
    /// entry comes first. The file appears only after the end marker arrived.
    /// Returns the size of the file. `onProgress` gets the bytes written.
    func backUp(
        volume: String, meta: VolumeBackupMeta, to destination: String, replace: Bool,
        onProgress: @escaping @Sendable (Int64) -> Void
    ) async -> Result<Int64, Failure> {
        if isCancelled { return .failure(.cancel) }
        let writer: PrivateFileWriter
        do {
            writer = try PrivateFileWriter(destination: destination, replace: replace)
        } catch {
            return .failure(Self.failure(error))  // no file exists
        }
        do {
            try writer.write(meta.entry())
        } catch {
            writer.abort()
            var f = Self.failure(error)
            f.wroteFile = true
            return .failure(f)
        }
        let result: Result<Int64, Failure> = await withHelper(volume: volume, readOnly: true) { id in
            let sink = ArchiveSink(writer: writer, stopOnContent: false, onProgress: onProgress)
            let end = await self.stream(id: id, sink: sink)
            sink.close()
            if self.isCancelled { return .failure(.cancel) }
            if let f = sink.failure { return .failure(f) }
            if let f = Self.streamFailure(end) { return .failure(f) }
            onProgress(sink.bytes)
            guard sink.isComplete else {
                return .failure(.text("The archive from Docker is not complete. The VM may have stopped."))
            }
            do {
                try writer.commit()
                return .success(writer.bytes)
            } catch {
                return .failure(Self.failure(error))
            }
        }
        if case .failure(var f) = result {
            writer.abort()
            f.wroteFile = true
            return .failure(f)
        }
        return result
    }

    // MARK: - Restore

    /// Sends the bytes of the file from `skip` to its end to the volume.
    /// `onProgress` gets the bytes sent.
    func restore(
        file path: String, skip: Int64, size: Int64, into volume: String,
        onProgress: @escaping @Sendable (Int64) -> Void
    ) async -> Failure? {
        if isCancelled { return .cancel }
        let fd = open(path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return .text("ColimaBar cannot read the file.") }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, Int64(st.st_size) == size else { return .text("The file changed. Try again.") }
        let result: Result<Void, Failure> = await withHelper(volume: volume, readOnly: false) { id in
            let upload = self.api.upload(
                "PUT", "/containers/\(id)/archive?path=/", fd: fd, offset: skip, length: size - skip,
                contentType: "application/x-tar", onProgress: onProgress)
            self.register(upload.handle)
            let reply = await upload.response.value
            if self.isCancelled { return .failure(.cancel) }
            guard let reply else { return .failure(.text("The connection to Docker ended early.")) }
            return reply.ok ? .success(()) : .failure(.text(Self.reason(reply)))
        }
        if case .failure(let f) = result { return f }
        return nil
    }

    // MARK: - Helper container

    private func withHelper<T>(
        volume: String, readOnly: Bool, _ body: (String) async -> Result<T, Failure>
    ) async -> Result<T, Failure> {
        if isCancelled { return .failure(.cancel) }
        let name = "colimabar-helper-\(newSuffix())"
        let json = HelperImage.containerBody(volume: volume, readOnly: readOnly)
        guard let r = await api.post("/containers/create?name=\(name)", json: json) else {
            return .failure(.text("Docker did not answer."))
        }
        guard r.ok, let id = (try? JSONDecoder().decode(APIIdResponse.self, from: r.body))?.Id,
            ColimaModel.isInspectable(id: id)
        else { return .failure(.text("Docker cannot create the helper container: \(Self.reason(r)).")) }
        let result = await body(id)
        // `force` and no `v=1`: the volume stays.
        let removed = await api.request("DELETE", "/containers/\(id)?force=1")
        if removed == nil || !(removed?.ok == true || removed?.status == 404) {
            lock.withLock { leftHelper = true }
            Self.log.error("cannot remove helper container \(name, privacy: .public)")
        }
        return result
    }

    // MARK: - Streams

    private struct End {
        let status: Int?
    }

    /// Streams `GET /containers/ID/archive?path=/v` into the sink. It returns
    /// when the daemon ends the stream, when the sink stops it or when the
    /// transfer is cancelled.
    private func stream(id: String, sink: ArchiveSink) async -> End {
        var handle: StreamHandle?
        let oneShot = OneShot()
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            oneShot.arm(cont)
            begin(oneShot)
            let started = api.streamRaw(
                "/containers/\(id)/archive?path=/v",
                onData: { [self] data in
                    if sink.consume(data) == .stop { stop() }
                },
                onEnd: { _ in oneShot.fire() })
            handle = started
            register(started)
        }
        end()
        return End(status: handle?.status)
    }

    private func begin(_ oneShot: OneShot) {
        let fire = lock.withLock {
            gate = oneShot
            stopped = false
            return cancelled
        }
        if fire { oneShot.fire() }
    }

    private func register(_ handle: StreamHandle) {
        let mustStop = lock.withLock {
            current = handle
            return cancelled || stopped
        }
        if mustStop { handle.cancel() }
    }

    private func stop() {
        let (handle, gate) = lock.withLock {
            stopped = true
            return (current, self.gate)
        }
        handle?.cancel()
        gate?.fire()
    }

    private func end() {
        lock.withLock {
            current = nil
            gate = nil
            stopped = false
        }
    }

    // MARK: - Reasons

    private static func streamFailure(_ end: End) -> Failure? {
        guard let status = end.status else { return .text("Docker did not answer.") }
        return (200..<300).contains(status) ? nil : .text("Docker cannot read the volume (HTTP \(status)).")
    }

    /// The message of the daemon, or the status. At most 120 characters.
    static func reason(_ r: DockerAPI.Response) -> String {
        if let m = (try? JSONDecoder().decode(APIMessage.self, from: r.body))?.message, !m.isEmpty {
            return String(m.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))
        }
        return "HTTP \(r.status)"
    }

    static func failure(_ error: Error) -> Failure {
        if let e = error as? POSIXError {
            switch e.code {
            case .ENOSPC: return .diskFull
            case .EEXIST: return exists
            case .EACCES, .EPERM: return .text("ColimaBar may not write there.")
            default: return .text(e.localizedDescription)
            }
        }
        return .text(error.localizedDescription)
    }
}

/// Resumes one continuation, once, from any thread. `fire` may come before `arm`.
/// `@unchecked Sendable`: `lock` guards both properties.
final class OneShot: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var fired = false

    func arm(_ c: CheckedContinuation<Void, Never>) {
        let resumeNow = lock.withLock {
            if !fired { continuation = c }
            return fired
        }
        if resumeNow { c.resume() }
    }

    func fire() {
        let c = lock.withLock {
            fired = true
            defer { continuation = nil }
            return continuation
        }
        c?.resume()
    }
}

/// Takes the chunks of an archive stream on the reader thread: it checks them
/// with `TarScanner` and writes them to the file. A failure stops the stream.
/// `@unchecked Sendable`: `lock` guards every mutable property.
private final class ArchiveSink: @unchecked Sendable {
    enum Action { case more, stop }

    private let lock = NSLock()
    private let writer: PrivateFileWriter?
    private let stopOnContent: Bool
    private let onProgress: @Sendable (Int64) -> Void
    private var scanner = TarScanner()
    private var closed = false
    private var written: Int64 = 0
    // The first chunk reports at once.
    private var lastReport = ContinuousClock.now.advanced(by: .seconds(-1))
    private var _failure: VolumeBackupRunner.Failure?

    init(writer: PrivateFileWriter?, stopOnContent: Bool, onProgress: @escaping @Sendable (Int64) -> Void) {
        self.writer = writer
        self.stopOnContent = stopOnContent
        self.onProgress = onProgress
    }

    var failure: VolumeBackupRunner.Failure? { lock.withLock { _failure } }
    var isComplete: Bool { lock.withLock { scanner.isComplete } }
    var sawContent: Bool { lock.withLock { scanner.sawContent } }
    var bytes: Int64 { lock.withLock { written } }

    /// After `close`, a late chunk does nothing.
    func close() { lock.withLock { closed = true } }

    func consume(_ data: Data) -> Action {
        let (action, report): (Action, Int64?) = lock.withLock {
            guard !closed, _failure == nil else { return (.stop, nil) }
            do {
                try scanner.feed(data)
                try writer?.write(data)
            } catch let e as TarScanner.Failure {
                switch e {
                case .unsafeEntry(let path): _failure = .text("The archive from Docker has an unsafe entry: \(path).")
                case .badHeader, .notComplete: _failure = .text("The archive from Docker is not valid.")
                }
                return (.stop, nil)
            } catch {
                _failure = VolumeBackupRunner.failure(error)
                return (.stop, nil)
            }
            if stopOnContent, scanner.sawContent { return (.stop, nil) }
            written += Int64(data.count)
            let now = ContinuousClock.now
            guard now - lastReport >= .milliseconds(100) else { return (.more, nil) }
            lastReport = now
            return (.more, written)
        }
        if let report { onProgress(report) }
        return action
    }
}
