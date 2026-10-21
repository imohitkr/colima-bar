import AppKit
import Foundation
import Network

/// HTTPS for container domains. The model makes the local certificate
/// authority (`LocalCA`), asks macOS to trust it for this user, and runs the
/// TLS listener of the proxy. Each dialog follows a click of the user, never
/// the launch, and the popover closes before it shows. A debug run does
/// none of this. The disk, the keychain and the TLS stack sit behind
/// `domainTLS`, so the tests use a fake.
extension ColimaModel {
    /// Runs `work` off the Swift concurrency pool. It blocks while a macOS dialog shows.
    nonisolated static func blocking<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async { continuation.resume(returning: work()) }
        }
    }

    func setHTTPSStatus(_ https: DomainStatus.HTTPS) {
        var status = domainStatus
        status.https = https
        setDomainStatus(status)
    }

    // MARK: - The switch

    /// The HTTPS switch calls it.
    func setHTTPS(_ on: Bool) {
        guard !isDebug, domainsEnabled, httpsSetupTask == nil else { return }
        if on, !httpsEnabled {
            enableHTTPS()
        } else if !on, httpsEnabled {
            disableHTTPS()
        }
    }

    /// Makes or loads the CA, trusts it (one dialog) and starts the listener.
    private func enableHTTPS() {
        dismissPopover()
        invalidateHTTPSTasks()
        setHTTPSStatus(.init(phase: .settingUp))
        let services = domainTLS
        let suffixes = activeDomainSuffixes
        httpsSetupTask = Task {
            defer { httpsSetupTask = nil }
            let prepared = await Self.blocking { Result { try services.prepareCA(permitted: suffixes) } }
            guard case .success(let ca) = prepared else {
                return setHTTPSStatus(
                    .init(
                        phase: .off,
                        problem: "HTTPS could not start. ColimaBar could not make the certificate authority."))
            }
            switch await Self.blocking({ services.install(ca) }) {
            case .done:
                tlsCA = ca
                setHTTPSEnabled(true)
                await startHTTPS()
            case .cancelled:
                services.removeCAFiles()
                setHTTPSStatus(.init(phase: .off, problem: "You cancelled the password dialog. HTTPS stays off."))
            case .failed(let status):
                services.removeCAFiles()
                setHTTPSStatus(.init(phase: .off, problem: "HTTPS could not start: macOS error \(status)."))
            }
        }
    }

    /// Stops HTTPS and removes the CA: the trust (one dialog), the keychain
    /// certificate and the key file. The key file goes even when the user
    /// cancels the dialog, so the CA can never sign again.
    private func disableHTTPS() {
        dismissPopover()
        tearDownHTTPS()
        let ca = tlsCA ?? domainTLS.loadCA()
        tlsCA = nil
        setHTTPSStatus(.init(phase: .removing))
        let services = domainTLS
        httpsSetupTask = Task {
            defer { httpsSetupTask = nil }
            var outcome = TrustStore.Outcome.done
            if let ca { outcome = await Self.blocking { services.uninstall(ca) } }
            services.removeCAFiles()
            setHTTPSEnabled(false)
            let note: String
            switch outcome {
            case _ where ca == nil:
                note =
                    "HTTPS is off. ColimaBar found no certificate authority file. If Keychain Access lists one, delete it there."
            case .done:
                note = "ColimaBar removed the certificate authority."
            case .cancelled:
                note =
                    "macOS still lists a trust setting for the removed certificate authority. It has no effect, because the key is deleted."
            case .failed(let status):
                note =
                    "macOS could not remove the trust setting (error \(status)). It has no effect, because the key is deleted."
            }
            setHTTPSStatus(.init(phase: .off, problem: note))
        }
    }

    private func setHTTPSEnabled(_ on: Bool) {
        setHTTPSEnabledFlag(on)
        if !isDebug { domainsStore.set(on, forKey: Defaults.Key.domainsHTTPS.rawValue) }
    }

    /// "Trust Again…": adds the CA to the login keychain and trusts it again.
    func trustCAAgain() {
        guard !isDebug, httpsEnabled, httpsSetupTask == nil, domainStatus.https.phase == .untrusted,
            let ca = tlsCA ?? domainTLS.loadCA()
        else { return }
        dismissPopover()
        let services = domainTLS
        let before = domainStatus.https
        httpsSetupTask = Task {
            defer { httpsSetupTask = nil }
            switch await Self.blocking({ services.install(ca) }) {
            case .done:
                let trusted = await Self.blocking { services.isTrusted(ca) }
                var https = domainStatus.https
                if https.listening { https.phase = trusted ? .running : .untrusted }
                setHTTPSStatus(https)
            case .cancelled, .failed:
                setHTTPSStatus(before)
            }
        }
    }

    /// Shows `ca.pem` in Finder, for tools with their own trust store.
    func showCACertificate() {
        let path = domainTLS.certificatePath
        guard !path.isEmpty, FileManager.default.fileExists(atPath: path) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    /// True while the CA exists: the switch is on, or a start is running.
    var caExists: Bool { httpsEnabled }

    // MARK: - Listener

    /// Starts the listener for a launch with the setting on. It shows no dialog.
    func startHTTPSAtLaunch() {
        guard httpsEnabled else { return }
        Task { await startHTTPS(retryFirst: true) }
    }

    /// Loads the CA, makes the identity provider, starts the TLS listener and
    /// tests it. It falls back to one certificate for all names if the
    /// per-name certificates fail the test. A missing trust only sets the
    /// `.untrusted` phase. It shows no dialog.
    func startHTTPS(retryFirst: Bool = false) async {
        guard !isDebug, domainsEnabled, httpsEnabled else { return }
        httpsStartToken += 1
        let token = httpsStartToken
        httpsRetry?.cancel()
        httpsRetry = nil
        multiSANTask?.cancel()
        multiSANTask = nil
        httpsStartPublished = domainBlockedPorts
        setHTTPSStatus(.init(phase: .settingUp))
        domainProxy.onHTTPSListenerFailure = { [weak self] in
            Task { @MainActor in self?.httpsListenerFailed(token: token) }
        }
        guard let ca = tlsCA ?? domainTLS.loadCA() else {
            return setHTTPSFailed(
                "The certificate authority files are missing. Turn HTTPS off and on.", retry: false)
        }
        tlsCA = ca
        guard let provider = await ensureTLSProvider(ca: ca) else {
            guard token == httpsStartToken else { return }
            return setHTTPSFailed("The TLS identity test failed.")
        }
        guard token == httpsStartToken, domainsEnabled, httpsEnabled else { return }
        let cache = LeafCache(ca: ca, provider: provider, suffixes: activeDomainSuffixes)
        leafCache = cache
        tlsMode = .perSNI
        guard var port = await listenHTTPS(cache: cache, mode: .perSNI, token: token, retryFirst: retryFirst) else {
            return
        }
        if await !domainTLS.selfTest(port: port, ca: ca) {
            guard token == httpsStartToken else { return }
            log.error("the HTTPS self-test failed with a certificate for each name")
            tlsMode = .multiSAN
            guard let again = await listenHTTPS(cache: cache, mode: .multiSAN, token: token, retryFirst: false)
            else { return }
            port = again
            guard await domainTLS.selfTest(port: port, ca: ca) else {
                guard token == httpsStartToken else { return }
                domainProxy.stopHTTPS()
                return setHTTPSFailed("The HTTPS self-test failed.")
            }
        }
        let services = domainTLS
        let trusted = await Self.blocking { services.isTrusted(ca) }
        guard token == httpsStartToken else { return }
        httpsRetryCount = 0
        setHTTPSStatus(.init(phase: trusted ? .running : .untrusted, port: port))
        // A container may have published the port while HTTPS started.
        if Self.httpsConflictPort(status: domainStatus, published: domainRoutes.publishedHostPorts) {
            if let port = domainStatus.https.port { noteDomainConflict(port: Int(port)) }
            rebindHTTPS()
        }
    }

    /// The provider that makes the identities. Callers that start together share one.
    private func ensureTLSProvider(ca: LocalCA) async -> TLSIdentityProvider? {
        if let tlsProvider { return tlsProvider }
        let services = domainTLS
        let task = httpsProviderTask ?? Task { await Self.blocking { services.makeProvider(ca: ca) } }
        httpsProviderTask = task
        let made = await task.value
        httpsProviderTask = nil
        guard httpsEnabled, domainsEnabled else {
            made?.removeAll()
            return nil
        }
        if tlsProvider == nil { tlsProvider = made }
        return tlsProvider
    }

    /// Starts the TLS listener on 443, else 8443. Sets the failure and returns nil if no port works.
    private func listenHTTPS(
        cache: LeafCache, mode: DomainTLSServer.Mode, token: Int, retryFirst: Bool
    ) async -> UInt16? {
        let candidates = DomainPorts.candidates(DomainPorts.https, published: httpsStartPublished)
        guard !candidates.isEmpty else {
            domainProxy.stopHTTPS()
            setHTTPSFailed(
                "Containers use ports 443 and 8443. ColimaBar tries again when the container ports change, and from time to time."
            )
            return nil
        }
        let names = mode == .multiSAN ? multiSANNames() : []
        multiSANServed = names
        let server = DomainTLSServer(cache: cache, mode: mode, names: names)
        let queue = tlsMintQueue
        let proxy = domainProxy
        let options: @Sendable () -> NWProtocolTLS.Options = { server.options(mintQueue: queue) }
        let first = DomainPorts.https[0]
        var port: UInt16?
        if candidates.first == first {
            port = await proxy.startHTTPS(candidates: [first], tls: options)
            if port == nil, retryFirst {
                try? await Task.sleep(for: .seconds(domainTimings.launchRetry))
                guard token == httpsStartToken else { return nil }
                port = await proxy.startHTTPS(candidates: [first], tls: options)
            }
        }
        guard token == httpsStartToken else { return nil }
        let rest = candidates.filter { $0 != first }
        if port == nil, !rest.isEmpty { port = await proxy.startHTTPS(candidates: rest, tls: options) }
        guard token == httpsStartToken else { return nil }
        if port == nil {
            setHTTPSFailed(
                "Ports 443 and 8443 are busy. ColimaBar tries again from time to time, when the container ports change and when the Mac wakes."
            )
        }
        return port
    }

    /// The names of the one certificate of the fallback mode: each route name and its subdomains, and `localhost`.
    private func multiSANNames() -> [String] {
        var names = [DomainName.localhost]
        for suffix in activeDomainSuffixes {
            names.append(suffix)
            names.append("*.\(suffix)")
            for relative in domainRoutes.routes.keys {
                let host = DomainLink.host(relative: relative, suffix: suffix)
                names += [host, "*.\(host)"]
            }
        }
        return Array(Set(names)).sorted()
    }

    /// In the fallback mode, the certificate lists the names. When the routes
    /// change, wait 2 s, then start the listener again with a new certificate.
    func syncMultiSANLeaf() {
        guard !isDebug, httpsEnabled, tlsMode == .multiSAN, domainStatus.https.listening, let cache = leafCache,
            let ca = tlsCA, multiSANNames() != multiSANServed
        else { return }
        multiSANTask?.cancel()
        let token = httpsStartToken
        multiSANTask = Task {
            try? await Task.sleep(for: .seconds(domainTimings.multiSANDebounce))
            guard !Task.isCancelled, token == httpsStartToken, domainStatus.https.listening else { return }
            multiSANTask = nil
            guard let port = await listenHTTPS(cache: cache, mode: .multiSAN, token: token, retryFirst: false),
                token == httpsStartToken
            else { return }
            var https = domainStatus.https
            https.port = port
            if await !domainTLS.selfTest(port: port, ca: ca), token == httpsStartToken {
                domainProxy.stopHTTPS()
                setHTTPSFailed("The HTTPS self-test failed.")
                return
            }
            setHTTPSStatus(https)
        }
    }

    // MARK: - Stop

    /// Makes every pending start and timer of HTTPS stale. `shutdown()` and the switches call it.
    func invalidateHTTPSTasks() {
        httpsStartToken += 1
        httpsRecheck?.cancel()
        httpsRecheck = nil
        httpsRetry?.cancel()
        httpsRetry = nil
        multiSANTask?.cancel()
        multiSANTask = nil
    }

    /// Stops the listener and deletes the temporary keychain. The CA stays.
    func tearDownHTTPS() {
        invalidateHTTPSTasks()
        httpsRetryCount = 0
        domainProxy.stopHTTPS()
        tlsProvider?.removeAll()
        tlsProvider = nil
        leafCache = nil
    }

    // MARK: - Retry, conflict and wake

    /// True when the HTTPS listener uses a port that a container publishes now.
    nonisolated static func httpsConflictPort(status: DomainStatus, published: Set<Int>) -> Bool {
        guard status.https.listening, let port = status.https.port else { return false }
        return published.contains(Int(port))
    }

    /// Shows the failure and plans the next try, with the waits of the HTTP proxy.
    private func setHTTPSFailed(_ problem: String, retry: Bool = true) {
        setHTTPSStatus(.init(phase: .failed, problem: problem))
        httpsRetry?.cancel()
        httpsRetry = nil
        guard retry else { return }
        let delay = domainTimings.failureDelay(attempt: httpsRetryCount)
        httpsRetryCount += 1
        let token = httpsStartToken
        httpsRetry = Task {
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, token == httpsStartToken, domainsEnabled, httpsEnabled, !isDebug,
                domainStatus.https.phase == .failed
            else { return }
            httpsRetry = nil
            await startHTTPS()
        }
    }

    private func httpsListenerFailed(token: Int) {
        guard !isDebug, domainsEnabled, httpsEnabled, token == httpsStartToken else { return }
        httpsStartToken += 1
        httpsRetryCount = 0
        setHTTPSFailed("The listener stopped. ColimaBar tries again soon.")
    }

    /// The routes changed. Fix a conflict, give a failed listener a new try, or go back to port 443.
    func reviewHTTPS(published: Set<Int>) {
        guard !isDebug, domainsEnabled, httpsEnabled, httpsSetupTask == nil else { return }
        switch domainStatus.https.phase {
        case .running, .untrusted:
            if Self.httpsConflictPort(status: domainStatus, published: published) {
                if let port = domainStatus.https.port { noteDomainConflict(port: Int(port)) }
                rebindHTTPS()
            } else {
                moveHTTPSBackToFirstPort(published: published)
            }
        case .failed:
            if domainBlockedPorts != httpsStartPublished { Task { await startHTTPS() } }
        default:
            break
        }
    }

    /// A container publishes the port of HTTPS now. Move to another port, at most once in 30 s.
    func rebindHTTPS() {
        guard !isDebug, domainsEnabled, httpsEnabled, domainStatus.https.listening, httpsRebindGapPassed() else {
            return
        }
        httpsRebindAt = Date()
        Task { await startHTTPS() }
    }

    /// True when the rebind gap has passed. If not, a check runs when it ends.
    private func httpsRebindGapPassed() -> Bool {
        guard let at = httpsRebindAt else { return true }
        let wait = domainTimings.rebindGap - Date().timeIntervalSince(at)
        guard wait > 0 else { return true }
        if httpsRecheck == nil {
            httpsRecheck = Task {
                try? await Task.sleep(for: .seconds(wait))
                guard !Task.isCancelled else { return }
                httpsRecheck = nil
                reviewHTTPS(published: domainRoutes.publishedHostPorts)
            }
        }
        return false
    }

    /// HTTPS runs on 8443. If port 443 is free now, move back to it.
    func moveHTTPSBackToFirstPort(published: Set<Int>? = nil) {
        guard !isDebug, domainsEnabled, httpsEnabled, domainStatus.https.listening, domainStatus.https.usesFallback,
            !httpsMoveBackProbing
        else { return }
        let first = DomainPorts.https[0]
        guard !(published ?? domainRoutes.publishedHostPorts).union(domainClaims.ports).contains(Int(first)) else {
            return
        }
        httpsMoveBackProbing = true
        httpsMoveBackAt = Date()
        let token = httpsStartToken
        let proxy = domainProxy
        Task {
            let free = await proxy.isFree(port: first)
            httpsMoveBackProbing = false
            guard free, token == httpsStartToken, domainStatus.https.listening, domainStatus.https.usesFallback,
                httpsRebindGapPassed()
            else { return }
            httpsRebindAt = Date()
            await startHTTPS()
        }
    }

    /// After a wake: unlock the temporary keychain and start the listener if it is gone.
    func httpsAfterWake() {
        guard !isDebug, domainsEnabled, httpsEnabled, httpsSetupTask == nil else { return }
        tlsProvider?.unlockIfNeeded()
        let phase = domainStatus.https.phase
        guard phase != .settingUp, phase != .removing else { return }
        if domainProxy.httpsPort == nil {
            Task { await startHTTPS() }
        } else {
            moveHTTPSBackToFirstPort()
        }
    }

    /// The heartbeat calls it. A listener on 8443 looks for a free port 443, at most once in a rebind gap.
    func httpsHeartbeat() {
        guard !isDebug, domainsEnabled, httpsEnabled, domainStatus.https.listening, domainStatus.https.usesFallback,
            Date().timeIntervalSince(httpsMoveBackAt) >= domainTimings.rebindGap
        else { return }
        moveHTTPSBackToFirstPort()
    }

    /// The line in the diagnostics file. It holds the state and counts, no names.
    var httpsStatusText: String {
        guard httpsEnabled else { return "off" }
        let https = domainStatus.https
        let phase: String
        switch https.phase {
        case .off: phase = "off"
        case .settingUp: phase = "starting"
        case .removing: phase = "removing"
        case .failed: phase = "failed"
        case .running, .untrusted: phase = "listening on port \(https.port.map(String.init) ?? "?")"
        }
        let mode = tlsMode == .perSNI ? "a certificate for each name" : "one certificate"
        return
            "\(phase), identity: \(tlsProvider?.name ?? "none"), \(mode), leaves made: \(leafCache?.mintedCount ?? 0), CA trusted: \(https.phase == .running ? "yes" : "no")"
    }
}
