import Foundation

extension ColimaModel {
    /// Runs `body` for each item, at most `limit` at a time, and returns the
    /// non-nil results (the names that failed).
    nonisolated static func failures<T: Sendable>(
        _ items: [T], limit: Int,
        _ body: @escaping @Sendable (T) async -> String?
    ) async -> [String] {
        await withTaskGroup(of: String?.self) { g in
            var rest = items[...]
            for _ in 0..<min(max(limit, 1), items.count) {
                let item = rest.removeFirst()
                g.addTask { await body(item) }
            }
            var out: [String] = []
            for await r in g {
                if let r { out.append(r) }
                if let item = rest.popFirst() { g.addTask { await body(item) } }
            }
            return out
        }
    }
}
