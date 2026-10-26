import Foundation

/// The calls of the image update check. They go to the Colima socket of one
/// profile (`api`), never to a proxy socket, so they never start the VM.
/// `/distribution` and `/images/create` make the daemon contact the registry.
struct ImageUpdateRunner: Sendable {
    let api: DockerAPI

    /// What the daemon says about the images of the containers.
    struct Scan: Equatable, Sendable {
        /// `Config.Image` of each container, by container ID.
        var configImages: [String: String] = [:]
        /// The local image of each reference, by full reference.
        var images: [String: ImageUpdateCheck.LocalImage] = [:]
    }

    /// The end of one pull.
    enum PullResult: Equatable, Sendable {
        case pulled
        case failed(ImageUpdateStatus.Failure, message: String)
        case cancelled
    }

    // MARK: - Local reads

    /// Reads `Config.Image` of the containers that `known` lacks, and the
    /// image of each reference. A container that is gone has no entry. Nil if
    /// the daemon does not answer: the caller keeps what it had.
    func scan(containerIDs: [String], known: [String: String]) async -> Scan? {
        var out = Scan()
        for id in containerIDs {
            if let image = known[id] {
                out.configImages[id] = image
                continue
            }
            guard let r = await api.get("/containers/\(id)/json") else { return nil }
            guard r.ok else { continue }
            guard let detail = try? JSONDecoder().decode(APIContainerDetail.self, from: r.body) else { continue }
            out.configImages[id] = detail.Config?.Image ?? ""
        }
        var refs: [String: ImageRef] = [:]
        for case .success(let ref) in out.configImages.values.map(ImageUpdateCheck.reference(of:)) {
            refs[ref.normalized] = ref
        }
        for (key, ref) in refs {
            guard let r = await api.get("/images/\(ImageArchiveRunner.pathEncoded(ref.normalized))/json") else {
                return nil
            }
            guard r.ok, let detail = try? JSONDecoder().decode(APIImageDetail.self, from: r.body) else { continue }
            out.images[key] = ImageUpdateCheck.LocalImage(detail)
        }
        return out
    }

    /// The CPU architecture of the VM in the names of the Docker API, or nil.
    func hostArchitecture() async -> String? {
        guard let r = await api.get("/info"), r.ok, let info = try? JSONDecoder().decode(APIInfo.self, from: r.body)
        else { return nil }
        return info.Architecture.map(ImageUpdateCheck.normalizedArchitecture)
    }

    // MARK: - Registry reads

    /// Asks the registry, through the daemon, for the digest of one tag.
    func distribution(_ ref: ImageRef, now: Date) async -> ImageUpdateCache.Entry {
        let path = "/distribution/\(ImageArchiveRunner.pathEncoded(ref.normalized))/json"
        let r = await api.get(path, timeout: 20)
        guard let r else { return .init(error: .unreachable, checkedAt: now) }
        guard r.ok else {
            let message = (try? JSONDecoder().decode(APIMessage.self, from: r.body))?.message
            return .init(error: ImageUpdateCheck.classify(status: r.status, message: message), checkedAt: now)
        }
        guard let digest = (try? JSONDecoder().decode(APIDistribution.self, from: r.body))?.Descriptor?.digest,
            digest.hasPrefix("sha256:")
        else { return .init(error: .other, checkedAt: now) }
        return .init(digest: digest, checkedAt: now)
    }

    /// Collects the answers of one run. `@unchecked Sendable`: `lock` guards
    /// every property.
    private final class Answers: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [String: ImageUpdateCache.Entry] = [:]
        private var stopped: Set<String> = []

        var all: [String: ImageUpdateCache.Entry] { lock.withLock { entries } }
        func isStopped(_ domain: String) -> Bool { lock.withLock { stopped.contains(domain) } }

        func add(_ entry: ImageUpdateCache.Entry, for ref: ImageRef) {
            lock.withLock {
                entries[ref.normalized] = entry
                // The first rate limit answer of a registry ends the run for it.
                if entry.error == .rateLimited { stopped.insert(ref.domain) }
            }
        }
    }

    /// Checks `refs`, `ImageUpdateSchedule.concurrency` at a time. After a
    /// rate limit answer, the other references of that registry wait. Their
    /// entries stay as they were.
    func check(_ refs: [ImageRef], now: Date) async -> [String: ImageUpdateCache.Entry] {
        let answers = Answers()
        _ = await ColimaModel.failures(refs, limit: ImageUpdateSchedule.concurrency) { ref in
            guard !answers.isStopped(ref.domain), !Task.isCancelled else { return nil }
            answers.add(await distribution(ref, now: now), for: ref)
            return nil
        }
        return answers.all
    }

    // MARK: - Pull

    /// Collects the lines of one pull. `@unchecked Sendable`: `lock` guards
    /// every property.
    private final class Pull: @unchecked Sendable {
        private let lock = NSLock()
        private var error: String?
        private var sawStatus = false
        private var handle: StreamHandle?
        private var continuation: CheckedContinuation<PullResult, Never>?
        private var done = false
        private var cancelled = false

        private struct Line: Decodable {
            struct Detail: Decodable { let message: String? }
            let status: String?
            let error: String?
            let errorDetail: Detail?
        }

        func read(_ data: Data) {
            guard let line = try? JSONDecoder().decode(Line.self, from: data) else { return }
            lock.withLock {
                if error == nil, let e = line.errorDetail?.message ?? line.error { error = e }
                if line.status?.hasPrefix("Status:") == true { sawStatus = true }
            }
        }

        func attach(_ h: StreamHandle) {
            let stop = lock.withLock {
                handle = h
                return cancelled
            }
            if stop { h.cancel() }
        }

        func install(_ c: CheckedContinuation<PullResult, Never>) {
            let stop = lock.withLock {
                continuation = c
                return cancelled
            }
            if stop { finish(.cancelled) }
        }

        func cancel() {
            let h = lock.withLock {
                cancelled = true
                return handle
            }
            h?.cancel()
            finish(.cancelled)
        }

        /// The daemon closed the stream.
        /// `body` is the start of the body of a non-2xx reply. It holds the
        /// message of the daemon.
        func ended(status: Int?, body: Data?) {
            let (message, complete) = lock.withLock { (error, sawStatus) }
            guard let status else {
                finish(.failed(.unreachable, message: "the daemon does not answer"))
                return
            }
            if let message {
                finish(.failed(ImageUpdateCheck.classify(status: status, message: message), message: message))
            } else if !(200..<300).contains(status) {
                let said = body.flatMap { try? JSONDecoder().decode(APIMessage.self, from: $0) }?.message
                finish(
                    .failed(
                        ImageUpdateCheck.classify(status: status, message: said), message: said ?? "HTTP \(status)"))
            } else if complete {
                finish(.pulled)
            } else {
                finish(.failed(.other, message: "the pull ended early"))
            }
        }

        private func finish(_ result: PullResult) {
            let c = lock.withLock { () -> CheckedContinuation<PullResult, Never>? in
                guard !done, let c = continuation else { return nil }
                done = true
                return c
            }
            c?.resume(returning: result)
        }
    }

    /// Pulls one tag. The daemon answers 200 and reports a failure in a line
    /// of the stream, so the lines decide. `platform` is `os/arch[/variant]`.
    /// A cancelled task stops the stream.
    func pull(_ ref: ImageRef, platform: String?) async -> PullResult {
        let enc = DockerAPI.percentEncoded
        var query = "fromImage=\(enc(ref.repository))&tag=\(enc(ref.tag))"
        if let platform { query += "&platform=\(enc(platform))" }
        let pull = Pull()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (c: CheckedContinuation<PullResult, Never>) in
                pull.install(c)
                let handle = api.stream(
                    "/images/create?\(query)", method: "POST", onLine: { pull.read($0) },
                    onEnd: { pull.ended(status: $0.status, body: $0.errorBody) })
                pull.attach(handle)
            }
        } onCancel: {
            pull.cancel()
        }
    }
}
