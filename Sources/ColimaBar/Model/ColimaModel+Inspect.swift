import Foundation

/// The reads of the Inspect page. They use the socket of the selected
/// profile, so they never start the VM.
extension ColimaModel {
    /// Reads one container. `digests` are the image digests that an earlier
    /// read found. With nil, this read asks for them once.
    func inspect(id: String, digests: [String]? = nil) async -> ContainerDetail.Outcome {
        guard hasDockerSocket, state == .running, Self.isInspectable(id: id) else { return .unavailable }
        let gen = generation
        let client = api
        guard let r = await client.get("/containers/\(id)/json"), gen == generation, state == .running else {
            return .unavailable
        }
        if r.status == 404 { return .gone }
        guard r.ok else { return .failed("HTTP \(r.status)") }
        let raw: APIContainerDetail
        do {
            raw = try JSONDecoder().decode(APIContainerDetail.self, from: r.body)
        } catch {
            return .failed(Self.inspectFailureReason(error))
        }
        let found: [String]
        if let digests {
            found = digests
        } else if let image = raw.Image, Self.isInspectable(id: image.replacingOccurrences(of: "sha256:", with: "")),
            let ir = await client.get("/images/\(image)/json"), ir.ok,
            let detail = try? JSONDecoder().decode(APIImageDetail.self, from: ir.body)
        {
            found = detail.RepoDigests ?? []
        } else {
            found = []
        }
        return .found(ContainerDetail.make(from: raw, digests: found))
    }

    /// The kind of a decoding error, with no value of the container in it.
    nonisolated static func inspectFailureReason(_ error: any Error) -> String {
        guard let e = error as? DecodingError else { return "unreadable answer" }
        switch e {
        case .typeMismatch: return "wrong type in the answer"
        case .valueNotFound: return "missing value in the answer"
        case .keyNotFound: return "missing field in the answer"
        case .dataCorrupted: return "answer is not JSON"
        @unknown default: return "unreadable answer"
        }
    }

    /// Logs a failed read of the Inspect page. The reason has no values.
    func logInspectFailure(_ reason: String) {
        log.error("inspect read failed: \(reason, privacy: .public)")
    }

    /// An ID is hex and goes in a request path. Anything else is not sent.
    nonisolated static func isInspectable(id: String) -> Bool {
        !id.isEmpty && id.utf8.count <= 64
            && id.utf8.allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66) }
    }
}
