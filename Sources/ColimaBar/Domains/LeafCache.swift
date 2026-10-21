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
/// A name outside the suffixes, a missing SNI value and an invalid name get
/// the leaf of `localhost`. A page can make a browser ask for many names, so
/// the cache holds at most `capacity` leaves (the least recently used one
/// goes first), and it mints at most `mintLimit` leaves in its life.
///
/// `lock` guards the table. `mintLock` makes the minters wait for each
/// other, so one name never gets two leaves. `@unchecked Sendable` for that.
final class LeafCache: @unchecked Sendable {
    private struct Entry {
        var identity: sec_identity_t
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
    private let mintLimit: Int
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
        ca: LocalCA, provider: TLSIdentityProvider, suffixes: [String], capacity: Int = 256, mintLimit: Int = 4096,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.provider = provider
        self.capacity = capacity
        self.mintLimit = mintLimit
        self.now = now
        setup = Setup(ca: ca, suffixes: suffixes)
    }

    /// The number of leaves that this cache has minted.
    var mintedCount: Int { lock.withLock { table.minted } }

    /// The name that a client with this SNI value gets: the normalized SNI
    /// value if it is a name under one of the suffixes, else `localhost`.
    static func mintName(sni: String?, suffixes: [String]) -> String {
        guard let sni, let host = DomainName.normalizedHost(sni),
            DomainName.relative(host, suffixes: suffixes) != nil
        else { return DomainName.localhost }
        return host
    }

    /// The identity for an SNI value.
    func identity(forSNI sni: String?) -> sec_identity_t? {
        let suffixes = lock.withLock { setup.suffixes }
        return identity(named: Self.mintName(sni: sni, suffixes: suffixes), names: nil)
    }

    /// One identity for all of `names`. It is for the fallback mode, which
    /// serves one certificate to each client.
    func multiSANIdentity(names: [String]) -> sec_identity_t? {
        let sorted = Array(Set(names)).sorted()
        return identity(named: "multi:" + sorted.joined(separator: ","), names: sorted)
    }

    /// Drops every leaf and signs the next ones with `ca`.
    func reset(ca: LocalCA, suffixes: [String]) {
        mintLock.withLock {
            lock.withLock {
                setup = Setup(ca: ca, suffixes: suffixes)
                table.entries = [:]
            }
        }
    }

    private func identity(named key: String, names: [String]?) -> sec_identity_t? {
        let current = now()
        if let hit = lookup(key, at: current) { return hit }
        return mintLock.withLock {
            // Another minter may have made it while this one waited.
            if let hit = lookup(key, at: current) { return hit }
            let limited = key != DomainName.localhost && lock.withLock { table.minted >= mintLimit }
            if limited {
                log.error("the leaf limit is reached")
                return lookup(DomainName.localhost, at: current)
                    ?? mint(DomainName.localhost, [DomainName.localhost], current)
            }
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
        lock.withLock {
            table.minted += 1
            table.clock += 1
            table.entries[key] = Entry(identity: secIdentity, notAfter: leaf.notAfter, used: table.clock)
            while table.entries.count > capacity,
                let oldest = table.entries.min(by: { $0.value.used < $1.value.used })
            {
                table.entries[oldest.key] = nil
            }
        }
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
