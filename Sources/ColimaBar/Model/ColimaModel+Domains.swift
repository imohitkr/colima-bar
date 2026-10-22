import AppKit
import Foundation

/// Container domains: names such as `web.shop.localhost` that the proxy
/// (`DomainProxy`) forwards to published ports. The model computes the routes
/// from the Docker list and gives them to the UI and to the proxy. A debug
/// run starts no listener: it may show the names (`domainsShownInDebug`).
/// The times of the proxy lifecycle. The tests make them short.
struct DomainTimings: Sendable {
    /// The wait before the second try of port 80 at the launch.
    var launchRetry: TimeInterval = 1
    /// The wait before the first try after the proxy failed. The next waits are
    /// 3, 12 and 60 times as long (5 s, 15 s, 60 s, then 5 min).
    var failureRetry: TimeInterval = 5
    /// How long the proxy waits before it moves again for a port.
    var rebindGap: TimeInterval = ColimaModel.domainRebindGap
    /// How long the fallback mode of HTTPS waits after a route change before it makes a new certificate.
    var multiSANDebounce: TimeInterval = 2
    /// How long the fallback mode of HTTPS serves one certificate before it makes a new one. A certificate lives 30 days.
    var multiSANRenew: TimeInterval = 29 * 86400
    /// The least time between two checks if macOS still trusts the certificate authority.
    var trustRecheck: TimeInterval = 60
    /// The waits before each new check of the system resolver while macOS does not use the resolver file yet.
    var dnsRecheck: [TimeInterval] = [2, 5, 15]

    /// The wait before try `attempt` (0 is the first) of a failed proxy.
    func failureDelay(attempt: Int) -> TimeInterval {
        let steps: [Double] = [1, 3, 12, 60]
        return failureRetry * steps[min(max(attempt, 0), steps.count - 1)]
    }
}

extension ColimaModel {
    /// How long the proxy waits before it moves again for a port.
    nonisolated static let domainRebindGap: TimeInterval = 30

    /// A debug run reads only `domainsShownInDebug`: the saved setting is for the real app.
    var domainsActive: Bool { isDebug ? domainsShownInDebug : domainsEnabled }

    /// The suffixes that name a container: `localhost` and the custom suffix.
    var activeDomainSuffixes: [String] { [DomainName.localhost] + [domainSuffix].compactMap { $0 } }

    /// The suffix that links use: the custom one while its DNS server works.
    /// HTTPS links use it only if the CA covers it, so a link never shows a
    /// certificate warning that a new CA would fix.
    var primaryDomainSuffix: String {
        guard let suffix = domainSuffix, domainStatus.dns.phase == .running else { return DomainName.localhost }
        if domainStatus.https.phase == .running, !(tlsCA?.covers([suffix]) ?? false) { return DomainName.localhost }
        return suffix
    }

    /// nil while the proxy does not listen, so a link never reaches another
    /// service on port 80. A debug run shows links with port 80.
    func domainURL(_ relative: String) -> URL? {
        let port: UInt16
        if !isDebug, domainStatus.https.phase == .running, let httpsPort = domainStatus.https.port {
            return DomainLink.url(relative: relative, suffix: primaryDomainSuffix, secure: true, port: httpsPort)
        }
        if isDebug {
            port = 80
        } else if domainStatus.phase == .running {
            port = domainStatus.httpPort ?? 80
        } else {
            return nil
        }
        return DomainLink.url(relative: relative, suffix: primaryDomainSuffix, secure: false, port: port)
    }

    func openDomain(_ relative: String) {
        if let url = domainURL(relative) { NSWorkspace.shared.open(url) }
    }

    /// True when the proxy listens on a port that a container publishes now.
    nonisolated static func domainConflictPort(status: DomainStatus, published: Set<Int>) -> Bool {
        guard status.phase == .running, let port = status.httpPort else { return false }
        return published.contains(Int(port))
    }

    // MARK: - Routes

    /// Keeps the candidates of the Docker list and rebuilds the routes if they changed.
    /// `authoritative` is false for the empty list of a stopped VM: it does not
    /// mean that the containers are gone, so the claimed ports stay.
    func updateDomainRoutes(_ list: [APIContainer], authoritative: Bool = true) {
        let candidates = list.compactMap(DomainCandidate.init)
        let published = DomainCandidate.publishedHostPorts(list)
        let oldClaims = domainClaims
        if authoritative {
            domainClaims.update(list)
            // A container that stopped or was removed has restarted or gone: the hint ends.
            setDomainRestartHints(domainRestartHints.filter { domainClaims.isRunning($0.id) })
        }
        // A profile switch changes the name on the 503 page, even if the list stays empty.
        guard
            candidates != domainCandidates || published != domainPublished || domainClaims != oldClaims
                || (domainsActive && domainRoutes.profile != profile)
        else { return }
        domainCandidates = candidates
        domainPublished = published
        rebuildDomainRoutes()
    }

    func rebuildDomainRoutes() {
        let table =
            domainsActive
            ? DomainRoutes.build(
                domainCandidates, suffixes: activeDomainSuffixes, profile: profile, vmRunning: state == .running,
                otherPublished: domainPublished, previous: domainRoutes, remember: httpsEnabled)
            : .empty
        setDomainRoutes(table)
        guard !isDebug else { return }
        domainProxy.routes = table
        reviewDomainProxy(published: table.publishedHostPorts)
        reviewHTTPS(published: table.publishedHostPorts)
        syncMultiSANLeaf()
    }

    /// Sets the HTTP part of the status. HTTPS keeps its own part.
    func setDomainHTTPStatus(phase: DomainStatus.Phase, httpPort: UInt16? = nil, problem: String? = nil) {
        var status = domainStatus
        status.phase = phase
        status.httpPort = httpPort
        status.problem = problem
        setDomainStatus(status)
    }

    /// The ports that the proxy must not use: the ports of the running containers,
    /// and the ports that a stopped container claims for its next start.
    var domainBlockedPorts: Set<Int> { domainRoutes.publishedHostPorts.union(domainClaims.ports) }

    /// The proxy holds a port that a running container publishes. Lima did not
    /// forward that port. Tell the user to restart the container, once for each container.
    func noteDomainConflict(port: Int) {
        let known = Set(domainRestartHints.map(\.id))
        let fresh = domainClaims.runningHolders(of: port).filter { !known.contains($0.id) }
        guard !fresh.isEmpty else { return }
        setDomainRestartHints(
            domainRestartHints + fresh.map { DomainRestartHint(id: $0.id, name: $0.name, port: port) })
        for c in fresh {
            record(c.name, "Port \(port) may not work on the Mac until the container restarts.", containerID: c.id)
        }
    }

    /// The routes changed. Fix a conflict, give a failed proxy a new try, or go back to port 80.
    private func reviewDomainProxy(published: Set<Int>) {
        guard domainsEnabled else { return }
        switch domainStatus.phase {
        case .running:
            if Self.domainConflictPort(status: domainStatus, published: published) {
                if let port = domainStatus.httpPort { noteDomainConflict(port: Int(port)) }
                rebindDomainProxy()
            } else {
                moveDomainProxyBackToFirstPort()
            }
        case .failed:
            if domainBlockedPorts != domainStartPublished { startDomainProxy() }
        default:
            break
        }
    }

    // MARK: - Proxy

    func domainsSettingChanged() {
        guard !isDebug else {
            setDomainStatus(DomainStatus(phase: .debugRun))
            rebuildDomainRoutes()
            return
        }
        if domainsEnabled {
            rebuildDomainRoutes()
            startDomainProxy()
            Task {
                await resumeHTTPS()
                // This follows the click on the master switch, so a dialog is fine.
                // A CA that a cancel or a master switch off left too wide goes now.
                if caIsWiderThanNeeded { await replaceCAForSuffixes() }
            }
            if domainSuffix != nil { Task { await startDNSResponder() } }
        } else {
            // The master switch off stops HTTPS but keeps the certificate authority.
            // It stops the DNS server too, but keeps the resolver file (no prompt).
            tearDownHTTPS()
            if httpsSetupTask == nil { setHTTPSStatus(.init(phase: .off)) }
            stopDNSResponder()
            stopDomainProxy()
            rebuildDomainRoutes()
        }
    }

    /// Starts the proxy on port 80, or on 8080 when 80 is busy or published. At
    /// the launch (`retryFirst`) it tries 80 once more after 1 s before it
    /// takes 8080: the old copy of the app may still be quitting.
    func startDomainProxy(retryFirst: Bool = false) {
        guard !isDebug, domainsEnabled else { return }
        domainStartToken += 1
        let token = domainStartToken
        domainStartPublished = domainBlockedPorts
        setDomainHTTPStatus(phase: .starting)
        let candidates = DomainPorts.candidates(DomainPorts.http, published: domainStartPublished)
        guard !candidates.isEmpty else {
            domainProxy.stop()
            setDomainFailed(
                "Containers use ports 80 and 8080. ColimaBar tries again when the container ports change, and from time to time."
            )
            return
        }
        domainRetry?.cancel()
        domainRetry = nil
        domainProxy.onListenerFailure = { [weak self] in
            Task { @MainActor in self?.domainListenerFailed(token: token) }
        }
        let first = DomainPorts.http[0]
        let delay = domainTimings.launchRetry
        let proxy = domainProxy
        Task {
            var port: UInt16?
            if candidates.first == first {
                port = await proxy.start(candidates: [first])
                if port == nil, retryFirst {
                    try? await Task.sleep(for: .seconds(delay))
                    guard token == domainStartToken else { return }
                    port = await proxy.start(candidates: [first])
                }
            }
            guard token == domainStartToken else { return }
            let rest = candidates.filter { $0 != first }
            if port == nil, !rest.isEmpty { port = await proxy.start(candidates: rest) }
            guard token == domainStartToken else { return }
            if let port {
                domainRetryCount = 0
                setDomainHTTPStatus(phase: .running, httpPort: port)
                // A container may have published the port while the proxy started.
                if Self.domainConflictPort(status: domainStatus, published: domainRoutes.publishedHostPorts) {
                    if let port = domainStatus.httpPort { noteDomainConflict(port: Int(port)) }
                    rebindDomainProxy()
                }
            } else {
                setDomainFailed(
                    "Ports 80 and 8080 are busy. ColimaBar tries again from time to time, when the container ports change and when the Mac wakes."
                )
            }
        }
    }

    /// Makes every pending start, retry and recheck stale, so that no late timer starts the proxy. `shutdown()` calls it.
    func invalidateDomainTasks() {
        domainStartToken += 1
        domainRecheck?.cancel()
        domainRecheck = nil
        domainRetry?.cancel()
        domainRetry = nil
    }

    func stopDomainProxy() {
        domainStartToken += 1
        domainRecheck?.cancel()
        domainRecheck = nil
        domainRetry?.cancel()
        domainRetry = nil
        domainRetryCount = 0
        domainProxy.stop()
        // The DNS server has its own state (`stopDNSResponder`).
        var status = DomainStatus()
        status.dns = domainStatus.dns
        setDomainStatus(status)
    }

    /// A container publishes the port of the proxy now. Move to another port,
    /// at most once in 30 s. Inside the gap, a later check runs when it ends.
    func rebindDomainProxy() {
        guard !isDebug, domainsEnabled, domainStatus.phase == .running else { return }
        guard domainRebindGapPassed() else { return }
        domainRebindAt = Date()
        startDomainProxy()
    }

    /// True when the rebind gap has passed. If not, a check runs when it ends.
    private func domainRebindGapPassed() -> Bool {
        if let at = domainRebindAt {
            let wait = domainTimings.rebindGap - Date().timeIntervalSince(at)
            if wait > 0 {
                scheduleDomainRecheck(after: wait)
                return false
            }
        }
        return true
    }

    private func scheduleDomainRecheck(after wait: TimeInterval) {
        guard domainRecheck == nil else { return }
        domainRecheck = Task {
            try? await Task.sleep(for: .seconds(wait))
            guard !Task.isCancelled else { return }
            domainRecheck = nil
            guard domainsEnabled, !isDebug, domainStatus.phase == .running else { return }
            reviewDomainProxy(published: domainRoutes.publishedHostPorts)
        }
    }

    /// The proxy runs on the fallback port. If port 80 is free now, move back to it.
    func moveDomainProxyBackToFirstPort() {
        guard !isDebug, domainsEnabled, domainStatus.phase == .running, domainStatus.usesFallback,
            !domainMoveBackProbing
        else { return }
        let first = DomainPorts.http[0]
        guard !domainBlockedPorts.contains(Int(first)) else { return }
        domainMoveBackProbing = true
        domainMoveBackAt = Date()
        let token = domainStartToken
        let proxy = domainProxy
        Task {
            let free = await proxy.isFree(port: first)
            domainMoveBackProbing = false
            guard free, token == domainStartToken, domainStatus.phase == .running, domainStatus.usesFallback,
                domainRebindGapPassed()
            else { return }
            domainRebindAt = Date()
            startDomainProxy()
        }
    }

    /// The listener normally survives a sleep. Start it again if it is gone.
    /// A proxy on the fallback port goes back to port 80 when that is free.
    func domainsAfterWake() {
        guard !isDebug, domainsEnabled else { return }
        httpsAfterWake()
        dnsAfterWake()
        guard domainStatus.phase != .starting else { return }
        if domainProxy.port == nil {
            startDomainProxy()
        } else {
            moveDomainProxyBackToFirstPort()
        }
    }

    /// The heartbeat calls it. A proxy on the fallback port looks for a free port 80, at most once in a rebind gap.
    func domainsHeartbeat() {
        httpsHeartbeat()
        guard !isDebug, domainsEnabled, domainStatus.phase == .running, domainStatus.usesFallback,
            Date().timeIntervalSince(domainMoveBackAt) >= domainTimings.rebindGap
        else { return }
        moveDomainProxyBackToFirstPort()
    }

    /// `token` is the start whose handler called. A newer start or stop makes the call stale.
    private func domainListenerFailed(token: Int) {
        guard !isDebug, domainsEnabled, token == domainStartToken else { return }
        domainStartToken += 1
        domainRetryCount = 0
        setDomainFailed("The proxy stopped. ColimaBar tries again soon.")
    }

    /// Shows the failure and plans the next try: after 5 s, 15 s, 60 s, then each 5 min.
    /// A change of the container ports, a wake or a new start also tries.
    private func setDomainFailed(_ problem: String) {
        setDomainHTTPStatus(phase: .failed, problem: problem)
        domainRetry?.cancel()
        let delay = domainTimings.failureDelay(attempt: domainRetryCount)
        domainRetryCount += 1
        let token = domainStartToken
        domainRetry = Task {
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, token == domainStartToken, domainsEnabled, !isDebug,
                domainStatus.phase == .failed
            else { return }
            domainRetry = nil
            startDomainProxy()
        }
    }

    /// The line in the diagnostics file. It holds counts and ports, no names.
    var domainStatusText: String {
        let phase: String
        switch domainStatus.phase {
        case .off: phase = "off"
        case .debugRun: phase = "debug run"
        case .starting: phase = "starting"
        case .running: phase = "listening on port \(domainStatus.httpPort.map(String.init) ?? "?")"
        case .failed: phase = "failed"
        }
        return "\(phase), \(domainRoutes.count) containers with a name"
    }
}
