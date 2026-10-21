import Foundation
import Network
import Security
import os

/// The server certificates of HTTPS, minted in memory when a client asks. A
/// handshake names the host in its SNI value (`mintName`): the cache signs a
/// leaf for that exact name with the local CA, and keeps it. Minting takes
/// about 5 ms, and Network.framework runs the challenge block several times
/// for each connection, so the cache is required.
///
/// The cache mints only for a name that the route table resolves (a route
/// name or a subdomain of one) and for the self-test name of each suffix.
/// Every other name, a missing SNI value and an invalid name get the leaf of
/// `localhost`, which is never minted again. A page can make a browser ask
/// for many names, so the cache holds at most `capacity` leaves. The least
/// recently used one goes first, and the provider deletes its key and
/// certificate.
///
/// `lock` guards the table. `mintLock` makes the minters wait for each
/// other, so one name never gets two leaves. `@unchecked Sendable` for that.
final class LeafCache: @unchecked Sendable {
    private struct Entry {
        var identity: sec_identity_t
        var certificate: SecCertificate
        var key: SecKey
        var notAfter: Date
        var used: UInt64
    }

    private struct State {
        var entries: [String: Entry] = [:]
        var clock: UInt64 = 0
        var minted = 0
    }

    private let provider: TLSIdentityProvider
    private let capacity: Int
    private let resolves: @Sendable (String) -> Bool
    private let now: @Sendable () -> Date
    /// Guards `table` and `setup`.
    private let lock = NSLock()
    private var table = State()
    private let mintLock = NSLock()
    private struct Setup {
        var ca: LocalCA
        var suffixes: [String]
    }

    private var setup: Setup
    private let log = Logger(category: "domains")

    /// A leaf with less than this time to live is made again.
    static let renewBefore: TimeInterval = 86400

    init(
        ca: LocalCA, provider: TLSIdentityProvider, suffixes: [String], capacity: Int = 256,
        resolves: @escaping @Sendable (String) -> Bool, now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.provider = provider
        self.capacity = capacity
        self.resolves = resolves
        self.now = now
        setup = Setup(ca: ca, suffixes: suffixes)
    }

    /// The number of leaves that this cache has minted, also the ones it dropped.
    var mintedCount: Int { lock.withLock { table.minted } }

    /// The name that a client with this SNI value gets: the normalized SNI
    /// value if it is the self-test name or a name that `resolves` accepts,
    /// else `localhost`.
    static func mintName(sni: String?, suffixes: [String], resolves: (String) -> Bool) -> String {
        guard let sni, let host = DomainName.normalizedHost(sni),
            let relative = DomainName.relative(host, suffixes: suffixes), !relative.isEmpty,
            relative == DomainName.selfTestLabel || resolves(host)
        else { return DomainName.localhost }
        return host
    }

    /// The identity for an SNI value.
    func identity(forSNI sni: String?) -> sec_identity_t? {
        let suffixes = lock.withLock { setup.suffixes }
        return identity(named: Self.mintName(sni: sni, suffixes: suffixes, resolves: resolves), names: nil)
    }

    /// One identity for all of `names`. It is for the fallback mode, which
    /// serves one certificate to each client.
    func multiSANIdentity(names: [String]) -> sec_identity_t? {
        let sorted = Array(Set(names)).sorted()
        return identity(named: Self.multiPrefix + sorted.joined(separator: ","), names: sorted)
    }

    /// Drops every leaf and signs the next ones with `ca`.
    func reset(ca: LocalCA, suffixes: [String]) {
        mintLock.withLock {
            let dropped = lock.withLock { () -> [Entry] in
                setup = Setup(ca: ca, suffixes: suffixes)
                defer { table.entries = [:] }
                return Array(table.entries.values)
            }
            discard(dropped)
        }
    }

    /// Drops the certificate of the fallback mode, so that the next one is new.
    func dropMultiSAN() {
        mintLock.withLock {
            let dropped = lock.withLock { () -> [Entry] in
                let keys = table.entries.keys.filter { $0.hasPrefix(Self.multiPrefix) }
                return keys.compactMap { table.entries.removeValue(forKey: $0) }
            }
            discard(dropped)
        }
    }

    private static let multiPrefix = "multi:"

    private func discard(_ entries: [Entry]) {
        for entry in entries { provider.discard(certificate: entry.certificate, key: entry.key) }
    }

    private func identity(named key: String, names: [String]?) -> sec_identity_t? {
        let current = now()
        if let hit = lookup(key, at: current) { return hit }
        return mintLock.withLock {
            // Another minter may have made it while this one waited.
            if let hit = lookup(key, at: current) { return hit }
            return mint(key, names ?? [key], current)
        }
    }

    /// Signs a leaf and stores it. `mintLock` is held.
    private func mint(_ key: String, _ names: [String], _ current: Date) -> sec_identity_t? {
        let ca = lock.withLock { setup.ca }
        guard let leaf = try? ca.mintLeaf(names: names, now: current),
            let id = try? provider.identity(certificate: leaf.certificate, key: leaf.key),
            let secIdentity = sec_identity_create(id)
        else {
            log.error("a leaf could not be made")
            return nil
        }
        let dropped = lock.withLock { () -> [Entry] in
            var dropped: [Entry] = []
            table.minted += 1
            table.clock += 1
            if let old = table.entries[key] { dropped.append(old) }
            table.entries[key] = Entry(
                identity: secIdentity, certificate: leaf.certificate, key: leaf.key, notAfter: leaf.notAfter,
                used: table.clock)
            while table.entries.count > capacity,
                let oldest = table.entries.min(by: { $0.value.used < $1.value.used })
            {
                dropped.append(oldest.value)
                table.entries[oldest.key] = nil
            }
            return dropped
        }
        discard(dropped)
        return secIdentity
    }

    private func lookup(_ key: String, at date: Date) -> sec_identity_t? {
        lock.withLock {
            guard var entry = table.entries[key], entry.notAfter.timeIntervalSince(date) >= Self.renewBefore else {
                return nil
            }
            table.clock += 1
            entry.used = table.clock
            table.entries[key] = entry
            return entry.identity
        }
    }
}
