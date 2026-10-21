import AppKit
import Foundation

/// Container domains: names such as `web.shop.localhost` that the proxy
/// (`DomainProxy`) forwards to published ports. The model computes the routes
/// from the Docker list and gives them to the UI and to the proxy. A debug
/// run starts no listener: it may show the names (`domainsShownInDebug`).
extension ColimaModel {
    /// How long the proxy waits before it moves again for a port conflict.
    nonisolated static let domainRebindGap: TimeInterval = 30

    var domainsActive: Bool { domainsEnabled || (isDebug && domainsShownInDebug) }

    /// The suffixes that name a container. The custom suffix of a later version adds to it.
    var activeDomainSuffixes: [String] { [DomainName.localhost] }

    /// The suffix that links use.
    var primaryDomainSuffix: String { activeDomainSuffixes.first ?? DomainName.localhost }

    func domainURL(_ relative: String) -> URL? {
        DomainLink.url(
            relative: relative, suffix: primaryDomainSuffix, secure: false, port: domainStatus.httpPort ?? 80)
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
        // A profile switch changes the name on the 503 page, even if the list stays empty.
        guard candidates != domainCandidates || (domainsActive && domainRoutes.profile != profile) else { return }
        domainCandidates = candidates
        rebuildDomainRoutes()
    }

    func rebuildDomainRoutes() {
        let table =
            domainsActive
            ? DomainRoutes.build(
                domainCandidates, suffixes: activeDomainSuffixes, profile: profile, vmRunning: state == .running)
            : .empty
        setDomainRoutes(table)
        guard !isDebug else { return }
        domainProxy.routes = table
        if Self.domainConflictPort(status: domainStatus, published: table.publishedHostPorts) { rebindDomainProxy() }
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

    /// Starts the proxy on port 80, or on 8080 when 80 is busy. At the launch
    /// (`retryFirst`) it tries 80 once more after 1 s: the old copy of the
    /// app may still be quitting.
    func startDomainProxy(retryFirst: Bool = false) {
        guard !isDebug, domainsEnabled else { return }
        domainStartToken += 1
        let token = domainStartToken
        setDomainStatus(DomainStatus(phase: .starting))
        let candidates = DomainPorts.candidates(DomainPorts.http, published: domainRoutes.publishedHostPorts)
        guard !candidates.isEmpty else {
            domainProxy.stop()
            setDomainStatus(DomainStatus(phase: .failed, problem: "Containers use ports 80 and 8080."))
            return
        }
        domainProxy.onListenerFailure = { [weak self] in
            Task { @MainActor in self?.domainListenerFailed() }
        }
        Task {
            var port = await domainProxy.start(candidates: candidates)
            if port == nil, retryFirst, candidates.first == DomainPorts.http[0] {
                try? await Task.sleep(for: .seconds(1))
                guard token == domainStartToken else { return }
                port = await domainProxy.start(candidates: candidates)
            }
            guard token == domainStartToken else { return }
            if let port {
                setDomainStatus(DomainStatus(phase: .running, httpPort: port))
            } else {
                setDomainStatus(DomainStatus(phase: .failed, problem: "Ports 80 and 8080 are busy."))
            }
        }
    }

    func stopDomainProxy() {
        domainStartToken += 1
        domainProxy.stop()
        setDomainStatus(DomainStatus())
    }

    /// A container publishes the port of the proxy now. Move to another port,
    /// at most once in 30 s.
    func rebindDomainProxy() {
        guard !isDebug, domainsEnabled, domainStatus.phase == .running else { return }
        let now = Date()
        if let at = domainRebindAt, now.timeIntervalSince(at) < Self.domainRebindGap { return }
        domainRebindAt = now
        startDomainProxy()
    }

    /// The listener normally survives a sleep. Start it again if it is gone.
    func domainsAfterWake() {
        guard !isDebug, domainsEnabled, domainProxy.port == nil, domainStatus.phase != .starting else { return }
        startDomainProxy()
    }

    private func domainListenerFailed() {
        guard !isDebug, domainsEnabled else { return }
        domainStartToken += 1
        let token = domainStartToken
        setDomainStatus(
            DomainStatus(phase: .failed, problem: "The proxy stopped. ColimaBar tries again in 5 seconds."))
        Task {
            try? await Task.sleep(for: .seconds(5))
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
