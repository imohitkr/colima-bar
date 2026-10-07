import Darwin
import Foundation
import os

/// One auto-start proxy for each Colima profile with the docker runtime, at
/// `~/.cache/colima-bar/profiles/PROFILE.sock`.
///
/// Each proxy has a fixed upstream: the Colima socket of its profile. A real
/// request to a stopped profile wakes that profile only. The stable socket
/// (Paths.proxySocket) is a separate proxy that follows the selected profile.
///
/// Each proxy holds one listening fd and one thread that waits in accept(),
/// so the idle cost stays the same as for the stable socket.
@MainActor
final class ProfileProxies {
    private let log = Logger(category: "proxy")
    /// The folder of the sockets (injectable for tests).
    let dir: String
    private let upstream: (String) -> String
    private let idleTimeout: Int
    private var proxies: [String: SocketProxy] = [:]
    private var listening = false
    /// Profiles whose socket path is too long. Each one is logged once.
    private var skipped: Set<String> = []

    /// Starts a profile and returns once Docker is ready (or false). The
    /// model sets it after init, because the closure captures the model.
    var wake: @Sendable (String) async -> Bool = { _ in false }

    /// The Docker API version for new proxies, to answer pings while the VM
    /// is stopped.
    var apiVersion: String?

    init(
        dir: String = Paths.profilesDir, upstream: @escaping (String) -> String = Paths.socket,
        idleTimeout: Int = 5 * 60
    ) {
        self.dir = dir
        self.upstream = upstream
        self.idleTimeout = idleTimeout
    }

    /// The profiles that have a proxy.
    var names: Set<String> { Set(proxies.keys) }

    /// The socket path of a profile's proxy, or nil if it has none.
    func path(for profile: String) -> String? { proxies[profile]?.path }

    /// Makes a proxy for each profile in `wanted` and removes the proxies of
    /// all other profiles, except the ones in `keep` (a VM action runs for
    /// them, for example a disk shrink that deletes the profile for a short
    /// time). It also removes old sockets in the folder that no proxy owns.
    func sync(wanted: Set<String>, keep: Set<String> = []) {
        for name in proxies.keys where !wanted.contains(name) && !keep.contains(name) {
            remove(name)
        }
        for name in wanted.sorted() where proxies[name] == nil {
            guard let path = ProfileSocket.path(dir: dir, profile: name) else {
                if skipped.insert(name).inserted {
                    log.error(
                        "no proxy socket for profile \(name, privacy: .public): the name is invalid or the path is longer than \(ProfileSocket.maxPathBytes) bytes"
                    )
                }
                continue
            }
            let px = SocketProxy(upstream: upstream(name), path: path, idleTimeout: idleTimeout, label: name)
            px.apiVersion = apiVersion
            let wake = self.wake
            px.wake = { await wake(name) }
            proxies[name] = px
            if listening { px.start() } else { px.stop() }
        }
        removeStrays()
    }

    /// Starts or stops all proxies (the auto-start setting). A stopped proxy
    /// leaves a symlink to the Colima socket of its profile.
    func setListening(_ on: Bool) {
        listening = on
        for px in proxies.values {
            if on { px.start() } else { px.stop() }
        }
    }

    /// On quit: each socket path becomes a symlink to the Colima socket of
    /// its profile, so docker clients keep working without ColimaBar.
    func shutdown() {
        setListening(false)
    }

    /// Removes the proxy and the socket of a profile, for example after a
    /// delete.
    func remove(_ profile: String) {
        proxies.removeValue(forKey: profile)?.remove()
    }

    /// Open work connections through a profile's proxy (see
    /// SocketProxy.activeTransfers).
    func activeTransfers(_ profile: String, now: Date = Date()) -> Int {
        proxies[profile]?.activeTransfers(now: now) ?? 0
    }

    func setAPIVersion(_ version: String?, for profile: String) {
        proxies[profile]?.apiVersion = version
    }

    func setAPIVersionForAll(_ version: String?) {
        apiVersion = version
        for px in proxies.values { px.apiVersion = version }
    }

    /// Deletes files in the folder that no proxy owns: sockets and links
    /// of profiles that are gone, and temporary files of a crashed run.
    private func removeStrays() {
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return }
        let owned = Set(proxies.values.map { ($0.path as NSString).lastPathComponent })
        for file in files where !owned.contains(file) {
            let stray =
                ProfileSocket.profile(fileName: file) != nil
                || file.hasSuffix(ProfileSocket.suffix + ".tmp") || file.hasSuffix(ProfileSocket.suffix + ".lnk")
            if stray { unlink("\(dir)/\(file)") }
        }
    }
}
