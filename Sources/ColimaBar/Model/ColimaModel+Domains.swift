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
    /// The wait before a try after the proxy stopped on its own.
    var failureRetry: TimeInterval = 5
    /// How long the proxy waits before it moves again for a port.
    var rebindGap: TimeInterval = ColimaModel.domainRebindGap
}

extension ColimaModel {
    /// How long the proxy waits before it moves again for a port.
    nonisolated static let domainRebindGap: TimeInterval = 30

    /// A debug run reads only `domainsShownInDebug`: the saved setting is for the real app.
    var domainsActive: Bool { isDebug ? domainsShownInDebug : domainsEnabled }

    /// The suffixes that name a container. The custom suffix of a later version adds to it.
    var activeDomainSuffixes: [String] { [DomainName.localhost] }

    /// The suffix that links use.
    var primaryDomainSuffix: String { activeDomainSuffixes.first ?? DomainName.localhost }

    /// nil while the proxy does not listen, so a link never reaches another
    /// service on port 80. A debug run shows links with port 80.
    func domainURL(_ relative: String) -> URL? {
        let port: UInt16
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
    func updateDomainRoutes(_ list: [APIContainer]) {
        let candidates = list.compactMap(DomainCandidate.init)
        let published = DomainCandidate.publishedHostPorts(list)
        // A profile switch changes the name on the 503 page, even if the list stays empty.
        guard
            candidates != domainCandidates || published != domainPublished
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
                otherPublished: domainPublished)
            : .empty
        setDomainRoutes(table)
        guard !isDebug else { return }
        domainProxy.routes = table
        reviewDomainProxy(published: table.publishedHostPorts)
    }

    /// The routes changed. Fix a conflict, give a failed proxy a new try, or go back to port 80.
    private func reviewDomainProxy(published: Set<Int>) {
        guard domainsEnabled else { return }
        switch domainStatus.phase {
        case .running:
            if Self.domainConflictPort(status: domainStatus, published: published) {
                rebindDomainProxy()
            } else {
                moveDomainProxyBackToFirstPort(published: published)
            }
        case .failed:
            if published != domainStartPublished { startDomainProxy() }
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
        } else {
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
        domainStartPublished = domainRoutes.publishedHostPorts
        setDomainStatus(DomainStatus(phase: .starting))
        let candidates = DomainPorts.candidates(DomainPorts.http, published: domainStartPublished)
        guard !candidates.isEmpty else {
            domainProxy.stop()
            setDomainStatus(
                DomainStatus(
                    phase: .failed,
                    problem: "Containers use ports 80 and 8080. ColimaBar tries again when the container ports change.")
            )
            return
        }
        domainProxy.onListenerFailure = { [weak self] in
            Task { @MainActor in self?.domainListenerFailed() }
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
                setDomainStatus(DomainStatus(phase: .running, httpPort: port))
                // A container may have published the port while the proxy started.
                if Self.domainConflictPort(status: domainStatus, published: domainRoutes.publishedHostPorts) {
                    rebindDomainProxy()
                }
            } else {
                setDomainStatus(
                    DomainStatus(
                        phase: .failed,
                        problem:
                            "Ports 80 and 8080 are busy. ColimaBar tries again when the container ports change or the Mac wakes."
                    ))
            }
        }
    }

    func stopDomainProxy() {
        domainStartToken += 1
        domainRecheck?.cancel()
        domainRecheck = nil
        domainProxy.stop()
        setDomainStatus(DomainStatus())
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
    func moveDomainProxyBackToFirstPort(published: Set<Int>? = nil) {
        guard !isDebug, domainsEnabled, domainStatus.phase == .running, domainStatus.usesFallback,
            !domainMoveBackProbing
        else { return }
        let first = DomainPorts.http[0]
        guard !(published ?? domainRoutes.publishedHostPorts).contains(Int(first)) else { return }
        domainMoveBackProbing = true
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
        guard !isDebug, domainsEnabled, domainStatus.phase != .starting else { return }
        if domainProxy.port == nil {
            startDomainProxy()
        } else {
            moveDomainProxyBackToFirstPort()
        }
    }

    private func domainListenerFailed() {
        guard !isDebug, domainsEnabled else { return }
        domainStartToken += 1
        let token = domainStartToken
        let delay = domainTimings.failureRetry
        setDomainStatus(
            DomainStatus(phase: .failed, problem: "The proxy stopped. ColimaBar tries again in 5 seconds."))
        Task {
            try? await Task.sleep(for: .seconds(delay))
            guard token == domainStartToken, domainsEnabled else { return }
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
