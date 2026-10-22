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
/// The cache mints for each route, not for each requested name. A name that
/// the route table resolves (a route name or a subdomain of one) gets the
/// leaf of its route, with the names `route` and `*.route`. The self-test
/// name of each suffix gets its own leaf. Every other name, a missing SNI
/// value and an invalid name get the leaf of `localhost`, which is never
/// minted again. So the number of leaves follows the number of routes,
/// whatever a page makes a browser ask for. As a backstop, the cache holds
/// at most `capacity` leaves. The least recently used one goes first. An
/// identity lives in memory only (`PKCS12`), so a dropped leaf is just freed.
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

    private let capacity: Int
    private let resolves: @Sendable (String) -> String?
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
        ca: LocalCA, suffixes: [String], capacity: Int = 256,
        resolves: @escaping @Sendable (String) -> String?, now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.capacity = capacity
        self.resolves = resolves
        self.now = now
        setup = Setup(ca: ca, suffixes: suffixes)
    }

    /// The number of leaves that this cache has minted, also the ones it dropped.
    var mintedCount: Int { lock.withLock { table.minted } }

    /// The number of leaves that the cache holds now.
    var leafCount: Int { lock.withLock { table.entries.count } }

    /// The name of the leaf that a client with this SNI value gets: the
    /// self-test name, the route name that `resolves` returns for the SNI
    /// value, or `localhost`.
    static func mintName(sni: String?, suffixes: [String], resolves: (String) -> String?) -> String {
        guard let sni, let host = DomainName.normalizedHost(sni),
            let relative = DomainName.relative(host, suffixes: suffixes), !relative.isEmpty
        else { return DomainName.localhost }
        if relative == DomainName.selfTestLabel { return host }
        return resolves(host) ?? DomainName.localhost
    }

    /// The names in the leaf of `name`: the route and its subdomains. The
    /// leaf of `localhost` has no wildcard.
    private static func leafNames(_ name: String) -> [String] {
        name == DomainName.localhost ? [name] : [name, "*.\(name)"]
    }

    /// The identity for an SNI value.
    func identity(forSNI sni: String?) -> sec_identity_t? {
        let suffixes = lock.withLock { setup.suffixes }
        let name = Self.mintName(sni: sni, suffixes: suffixes, resolves: resolves)
        return identity(named: name, names: Self.leafNames(name))
    }

    /// One identity for all of `names`. It is for the fallback mode, which
    /// serves one certificate to each client. A new `epoch` makes a new
    /// certificate for the same names, and `dropMultiSAN(except:)` ends the old ones.
    func multiSANIdentity(names: [String], epoch: Int = 0) -> sec_identity_t? {
        let sorted = Array(Set(names)).sorted()
        return identity(named: Self.multiPrefix(epoch) + sorted.joined(separator: ","), names: sorted)
    }

    /// Drops the certificates of the fallback mode, except the ones of `epoch`.
    /// Call it after the listener of that epoch runs, so that the old
    /// listener never serves a certificate that is gone.
    func dropMultiSAN(except epoch: Int? = nil) {
        mintLock.withLock {
            let keep = epoch.map { Self.multiPrefix($0) }
            lock.withLock {
                let keys = table.entries.keys.filter { key in
                    key.hasPrefix("multi:") && !(keep.map { key.hasPrefix($0) } ?? false)
                }
                for key in keys { table.entries[key] = nil }
            }
        }
    }

    private static func multiPrefix(_ epoch: Int) -> String { "multi:\(epoch):" }

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
        let leaf: (certificate: SecCertificate, key: SecKey, notAfter: Date)
        do {
            leaf = try ca.mintLeaf(names: names, now: current)
        } catch {
            log.error("a leaf could not be signed: \(TLSIdentities.logText(error), privacy: .public)")
            return nil
        }
        let id: SecIdentity
        do {
            id = try PKCS12.identity(certificate: leaf.certificate, key: leaf.key)
        } catch {
            log.error("a leaf could not be made an identity: \(TLSIdentities.logText(error), privacy: .public)")
            return nil
        }
        guard let secIdentity = sec_identity_create(id) else {
            log.error("a leaf identity could not be wrapped for Network.framework")
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
