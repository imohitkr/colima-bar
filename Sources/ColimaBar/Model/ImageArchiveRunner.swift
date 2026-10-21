import CryptoKit
import Darwin
import Foundation

/// The Docker calls that save images to a tar file and load them again, for
/// the VM type change. It talks to the socket of one profile only (the
/// `DockerAPI` of the caller), so it never starts the VM.
///
/// `save` streams `GET /images/get` into a private file and computes its
/// SHA-256 while it writes. `load` checks the SHA-256 against the
/// value of the journal before it sends one byte to Docker, so a file that
/// someone swapped is refused.
///
/// One operation at a time uses a runner. `cancel()` can come from any thread.
/// `@unchecked Sendable`: `lock` guards every mutable property.
final class ImageArchiveRunner: @unchecked Sendable {
    typealias Failure = VolumeBackupRunner.Failure

    private let api: DockerAPI
    private let lock = NSLock()
    private var cancelled = false
    private var current: StreamHandle?
    private var gate: OneShot?

    init(api: DockerAPI) { self.api = api }

    var isCancelled: Bool { lock.withLock { cancelled } }

    /// Stops the operation that runs now. It ends with `Failure.cancel`.
    func cancel() {
        let (handle, gate) = lock.withLock {
            cancelled = true
            return (current, self.gate)
        }
        handle?.cancel()
        gate?.fire()
    }

    // MARK: - Save

    /// Streams `GET /images/get?names=R1&names=R2…` into a new private file.
    /// `TarScanner` checks every header and the end marker, and the file
    /// appears only after the end marker arrived. Returns the size and the
    /// SHA-256 of the file. `onProgress` gets the bytes written.
    func save(
        refs: [String], to path: String, onProgress: @escaping @Sendable (Int64) -> Void
    ) async -> Result<(bytes: Int64, sha256: String), Failure> {
        guard !refs.isEmpty else { return .failure(.text("There are no images to save.")) }
        if isCancelled { return .failure(.cancel) }
        let writer: PrivateFileWriter
        do { writer = try PrivateFileWriter(destination: path, replace: false) } catch {
            return .failure(VolumeBackupRunner.failure(error))
        }
        let query = refs.map { "names=" + DockerAPI.percentEncoded($0) }.joined(separator: "&")
        let sink = ImageSink(writer: writer, onProgress: onProgress)
        var handle: StreamHandle?
        let oneShot = OneShot()
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            oneShot.arm(cont)
            let fire = lock.withLock {
                gate = oneShot
                return cancelled
            }
            if fire { oneShot.fire() }
            let started = api.streamRaw(
                "/images/get?\(query)",
                onData: { [self] data in
                    if sink.consume(data) == .stop { stop() }
                },
                onEnd: { _ in oneShot.fire() })
            handle = started
            register(started)
        }
        lock.withLock {
            current = nil
            gate = nil
        }
        sink.close()
        if isCancelled {
            writer.abort()
            return .failure(.cancel)
        }
        if let f = sink.failure {
            writer.abort()
            return .failure(f)
        }
        guard let status = handle?.status else {
            writer.abort()
            return .failure(.text("Docker did not answer."))
        }
        guard (200..<300).contains(status) else {
            writer.abort()
            return .failure(.text("Docker cannot save the images (HTTP \(status))."))
        }
        guard sink.isComplete else {
            writer.abort()
            return .failure(.text("The archive from Docker is not complete. The VM may have stopped."))
        }
        onProgress(sink.bytes)
        do {
            try writer.commit()
        } catch {
            return .failure(VolumeBackupRunner.failure(error))
        }
        return .success((writer.bytes, sink.sha256))
    }

    // MARK: - Missing

    /// The references that answer 404 on `GET /images/REF/json`. Nil if the
    /// daemon does not answer, or answers with another error.
    func missing(_ refs: [String]) async -> [String]? {
        var out: [String] = []
        for ref in refs {
            if isCancelled { return nil }
            guard let r = await api.get("/images/\(Self.pathEncoded(ref))/json") else { return nil }
            if r.status == 404 {
                out.append(ref)
            } else if !r.ok {
                return nil
            }
        }
        return out
    }

    static func pathEncoded(_ ref: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ":/.-_@"))
        return ref.addingPercentEncoding(withAllowedCharacters: allowed) ?? ref
    }

    // MARK: - Load

    /// Checks the SHA-256 of the file against the journal, then sends it to
    /// `POST /images/load`. The check and the upload use the same open file.
    /// `onProgress` gets the bytes sent. Nil means that Docker loaded it.
    func load(
        file path: String, sha256: String, onProgress: @escaping @Sendable (Int64) -> Void
    ) async -> Failure? {
        if isCancelled { return .cancel }
        let fd = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { return .text("ColimaBar cannot read the image file.") }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_size > 0 else {
            return .text("ColimaBar cannot read the image file.")
        }
        let size = Int64(st.st_size)
        let digest = await hash(fd: fd, size: size)
        if isCancelled { return .cancel }
        guard digest == sha256 else { return .text("The image file changed. ColimaBar does not load it.") }
        let upload = api.upload(
            "POST", "/images/load?quiet=1", fd: fd, offset: 0, length: size, contentType: "application/x-tar",
            onProgress: onProgress)
        register(upload.handle)
        let reply = await upload.response.value
        lock.withLock { current = nil }
        if isCancelled { return .cancel }
        guard let reply else { return .text("The connection to Docker ended early.") }
        guard reply.ok else { return .text(VolumeBackupRunner.reason(reply)) }
        return Self.loadError(in: reply.body).map { .text($0) }
    }

    /// The message of an `error` or `errorDetail` line in the reply of
    /// `POST /images/load`, cut to 120 characters. Nil if there is none.
    static func loadError(in body: Data) -> String? {
        for line in String(decoding: body, as: UTF8.self).split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            let detail = (object["errorDetail"] as? [String: Any])?["message"] as? String
            if let message = detail ?? object["error"] as? String {
                return String(message.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))
            }
        }
        return nil
    }

    /// The SHA-256 of the first `size` bytes of the file, as hex. It reads on
    /// a background thread and stops at a cancel.
    private func hash(fd: Int32, size: Int64) async -> String? {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                var hasher = SHA256()
                var buffer = [UInt8](repeating: 0, count: 1 << 20)
                var done: Int64 = 0
                while done < size {
                    if self.isCancelled {
                        cont.resume(returning: nil)
                        return
                    }
                    let n = pread(fd, &buffer, Int(min(Int64(buffer.count), size - done)), off_t(done))
                    if n < 0, errno == EINTR { continue }
                    guard n > 0 else {
                        cont.resume(returning: nil)
                        return
                    }
                    hasher.update(data: buffer[0..<n])
                    done += Int64(n)
                }
                cont.resume(returning: Self.hex(hasher.finalize()))
            }
        }
    }

    static func hex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Handles

    private func register(_ handle: StreamHandle) {
        let mustStop = lock.withLock {
            current = handle
            return cancelled
        }
        if mustStop { handle.cancel() }
    }

    /// The sink found a failure: stop the stream.
    private func stop() {
        let (handle, gate) = lock.withLock { (current, self.gate) }
        handle?.cancel()
        gate?.fire()
    }
}

/// Takes the chunks of the image stream on the reader thread: it checks them
/// with `TarScanner`, writes them to the file and adds them to the SHA-256. A
/// failure stops the stream. `@unchecked Sendable`: `lock` guards every
/// mutable property.
private final class ImageSink: @unchecked Sendable {
    enum Action { case more, stop }

    private let lock = NSLock()
    private let writer: PrivateFileWriter
    private let onProgress: @Sendable (Int64) -> Void
    private var scanner = TarScanner(names: .any)
    private var hasher = SHA256()
    private var closed = false
    private var written: Int64 = 0
    private var lastReport = ContinuousClock.now.advanced(by: .seconds(-1))
    private var _failure: VolumeBackupRunner.Failure?

    init(writer: PrivateFileWriter, onProgress: @escaping @Sendable (Int64) -> Void) {
        self.writer = writer
        self.onProgress = onProgress
    }

    var failure: VolumeBackupRunner.Failure? { lock.withLock { _failure } }
    var isComplete: Bool { lock.withLock { scanner.isComplete } }
    var bytes: Int64 { lock.withLock { written } }
    var sha256: String { lock.withLock { ImageArchiveRunner.hex(hasher.finalize()) } }

    /// After `close`, a late chunk does nothing.
    func close() { lock.withLock { closed = true } }

    func consume(_ data: Data) -> Action {
        let (action, report): (Action, Int64?) = lock.withLock {
            guard !closed, _failure == nil else { return (.stop, nil) }
            do {
                try scanner.feed(data)
                try writer.write(data)
            } catch is TarScanner.Failure {
                _failure = .text("The archive from Docker is not valid.")
                return (.stop, nil)
            } catch {
                _failure = VolumeBackupRunner.failure(error)
                return (.stop, nil)
            }
            hasher.update(data: data)
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
