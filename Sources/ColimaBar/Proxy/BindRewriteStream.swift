import Foundation

/// The bytes that a client sends to the daemon on one proxy connection, with
/// `BindPathRewrite` applied to each container create request.
///
/// It reads each request head, and passes each body through by its
/// `Content-Length`. It holds only a create body, until the body is complete.
/// At the first request that it cannot follow, it passes all later bytes
/// through unchanged: a chunked body, a head without a known method, a bad
/// `Content-Length`, or a request that can switch the connection to a raw
/// stream (an `Upgrade` header, attach, exec start, a BuildKit session).
/// Thus attach, exec, builds and event streams keep working.
///
/// One thread uses an instance: the copy from the client to the daemon.
final class BindRewriteStream {
    private enum State {
        /// The start of a request head, not yet sent.
        case head(Data)
        /// The bytes of a body that are left to pass through.
        case body(Int)
        /// A create request, held until its body has `length` bytes.
        case hold(head: Data, body: Data, length: Int)
        /// Everything passes through unchanged.
        case raw
    }

    private var state = State.head(Data())

    /// Decides if the profile shares `/private/tmp`. The stream asks only for
    /// a create request that binds a path in `/tmp`.
    private let isTargetShared: () -> Bool

    init(isTargetShared: @escaping () -> Bool) {
        self.isTargetShared = isTargetShared
    }

    /// True once the stream passes all bytes through unchanged.
    var isRaw: Bool {
        if case .raw = state { return true }
        return false
    }

    /// Takes the next bytes from the client and gives the bytes for the daemon
    /// to `emit`. Returns false as soon as `emit` returns false.
    func feed(_ chunk: UnsafeRawBufferPointer, emit: (UnsafeRawBufferPointer) -> Bool) -> Bool {
        var input = chunk[...]
        while !input.isEmpty {
            switch state {
            case .raw:
                return emit(UnsafeRawBufferPointer(rebasing: input))
            case .body(let left):
                let part = input.prefix(left)
                guard emit(UnsafeRawBufferPointer(rebasing: part)) else { return false }
                input = input.dropFirst(part.count)
                state = left == part.count ? .head(Data()) : .body(left - part.count)
            case .hold(let head, var body, let length):
                let part = input.prefix(length - body.count)
                body.append(contentsOf: part)
                input = input.dropFirst(part.count)
                guard body.count == length else {
                    state = .hold(head: head, body: body, length: length)
                    continue
                }
                state = .head(Data())
                guard send(request(head: head, body: body), emit) else { return false }
            case .head(var pending):
                pending.append(contentsOf: input)
                input = input.dropFirst(input.count)
                return takeHead(pending, emit)
            }
        }
        return true
    }

    /// Gives the bytes that the stream still holds to `emit`, unchanged, for
    /// example when the client closes in the middle of a request.
    func finish(emit: (UnsafeRawBufferPointer) -> Bool) -> Bool {
        let held: Data
        switch state {
        case .head(let pending): held = pending
        case .hold(let head, let body, _): held = head + body
        case .body, .raw: held = Data()
        }
        state = .raw
        return held.isEmpty || send(held, emit)
    }

    /// Handles the bytes of a head that started in an earlier chunk, and any
    /// bytes after the head.
    private func takeHead(_ pending: Data, _ emit: (UnsafeRawBufferPointer) -> Bool) -> Bool {
        let marker = Data("\r\n\r\n".utf8)
        guard let end = pending.range(of: marker) else {
            // Bytes that cannot start a request, or a head that is too large.
            if pending.count >= SocketProxy.maxHead || !Self.mayStartRequest(pending) {
                return passRaw(pending, emit)
            }
            state = .head(pending)
            return true
        }
        let head = pending[..<end.upperBound]
        let rest = pending[end.upperBound...]
        let line = head.withUnsafeBytes { SocketProxy.requestLine($0) }
        guard !line.isEmpty, !Self.mayHijack(line, head: head),
            let length = head.withUnsafeBytes({ SocketProxy.bodyLength($0) })
        else { return passRaw(pending, emit) }
        if BindPathRewrite.isContainerCreate(line), length > 0, length <= BindPathRewrite.maxBody,
            !Self.hasHeader("expect", in: head)
        {
            // A client that sends "Expect: 100-continue" waits for the daemon
            // before it sends the body, so the stream must not hold the head.
            state = .hold(head: Data(head), body: Data(), length: length)
        } else {
            state = length > 0 ? .body(length) : .head(Data())
            guard send(Data(head), emit) else { return false }
        }
        return rest.isEmpty || Data(rest).withUnsafeBytes { feed($0, emit: emit) }
    }

    /// The bytes to send for a complete create request.
    private func request(head: Data, body: Data) -> Data {
        guard let new = BindPathRewrite.rewrittenRequest(head: head, body: body), isTargetShared() else {
            return head + body
        }
        return new
    }

    private func passRaw(_ data: Data, _ emit: (UnsafeRawBufferPointer) -> Bool) -> Bool {
        state = .raw
        return send(data, emit)
    }

    private func send(_ data: Data, _ emit: (UnsafeRawBufferPointer) -> Bool) -> Bool {
        data.withUnsafeBytes { emit($0) }
    }

    /// False if the first bytes cannot be the start of a request line: no
    /// known method followed by a space within 8 bytes.
    private static func mayStartRequest(_ pending: Data) -> Bool {
        let first = pending.prefix(8)
        guard let space = first.firstIndex(of: 0x20) else { return first.count < 8 }
        return SocketProxy.methods.contains(String(decoding: first[..<space], as: UTF8.self))
    }

    /// True for a request after which the connection can carry a raw stream:
    /// an `Upgrade` header, attach, exec start, or a BuildKit session.
    private static func mayHijack(_ line: String, head: Data) -> Bool {
        if hasHeader("upgrade", in: head) { return true }
        let parts = line.split(separator: " ")
        guard parts.count >= 2 else { return true }
        var path = String(parts[1].split(separator: "?", maxSplits: 1).first ?? "")
        if path.hasPrefix("/v"), let slash = path.dropFirst().firstIndex(of: "/") { path = String(path[slash...]) }
        return path == "/session" || path.hasPrefix("/grpc") || path.hasSuffix("/attach")
            || path.hasSuffix("/attach/ws") || (path.hasPrefix("/exec/") && path.hasSuffix("/start"))
    }

    /// True if the head has a header with this lower-case name.
    private static func hasHeader(_ name: String, in head: Data) -> Bool {
        let prefix = Array((name + ":").utf8)
        return head.split(separator: 0x0A).contains { line in
            line.count >= prefix.count && zip(line, prefix).allSatisfy { $0 | 0x20 == $1 }
        }
    }
}
