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

    /// True when the CA covers every active name and permits one more (for
    /// example a suffix that is gone). A cancelled or skipped replacement leaves such a CA.
    var caIsWiderThanNeeded: Bool {
        guard !isDebug, httpsEnabled, let ca = tlsCA else { return false }
        return ca.covers(activeDomainSuffixes) && Set(ca.permitted) != Set(activeDomainSuffixes)
    }

    func setHTTPSStatus(_ https: DomainStatus.HTTPS) {
        var status = domainStatus
        status.https = https
        status.https.widerCA = caIsWiderThanNeeded
        setDomainStatus(status)
    }

    // MARK: - The switch

    /// The HTTPS switch calls it. Turning HTTPS off works when the master
    /// switch is off too, so the CA can always go.
    func setHTTPS(_ on: Bool) {
        guard !isDebug, httpsSetupTask == nil else { return }
        if on, !httpsEnabled {
            guard domainsEnabled else { return }
            enableHTTPS()
        } else if !on, httpsEnabled {
            disableHTTPS()
        }
    }

    /// True while a CA install runs or ran when the app ended. The next launch cleans up.
    var httpsInstallPending: Bool { domainsStore.bool(forKey: Defaults.Key.domainsHTTPSPending.rawValue) }

    private func setHTTPSInstallPending(_ on: Bool) {
        guard !isDebug else { return }
        if on {
            domainsStore.set(true, forKey: Defaults.Key.domainsHTTPSPending.rawValue)
        } else {
            domainsStore.removeObject(forKey: Defaults.Key.domainsHTTPSPending.rawValue)
        }
    }

    /// True while a CA removal runs or ran when the app ended. The next launch offers a clean-up.
    var httpsRemovalPending: Bool { domainsStore.bool(forKey: Defaults.Key.domainsHTTPSRemoving.rawValue) }

    private func setHTTPSRemovalPending(_ on: Bool) {
        guard !isDebug else { return }
        if on {
            domainsStore.set(true, forKey: Defaults.Key.domainsHTTPSRemoving.rawValue)
        } else {
            domainsStore.removeObject(forKey: Defaults.Key.domainsHTTPSRemoving.rawValue)
        }
    }

    /// Closes the popover before a dialog. It returns true when a dashboard was open,
    /// so the flow can bring it back with `restoreDashboard(ifOpen:)`.
    func closeDashboardForDialog() -> Bool {
        let wasOpen = visibleCount > 0
        dismissPopover()
        return wasOpen
    }

    /// After a dialog, with any outcome: shows the dashboard again, key and focused.
    func restoreDashboard(ifOpen wasOpen: Bool) {
        if wasOpen { restoreDashboard() }
    }

    /// Makes or loads the CA, trusts it (one dialog) and starts the listener.
    private func enableHTTPS() {
        let wasOpen = closeDashboardForDialog()
        invalidateHTTPSTasks()
        setHTTPSStatus(.init(phase: .settingUp))
        let services = domainTLS
        let suffixes = activeDomainSuffixes
        httpsSetupTask = Task {
            defer {
                httpsSetupTask = nil
                restoreDashboard(ifOpen: wasOpen)
            }
            let prepared = await Self.blocking { Result { try services.prepareCA(permitted: suffixes) } }
            guard !Task.isCancelled else { return }
            guard case .success(let ca) = prepared else {
                return setHTTPSStatus(
                    .init(
                        phase: .off,
                        problem: "HTTPS could not start. ColimaBar could not make the certificate authority."))
            }
            await install(ca)
        }
    }

    /// Installs a CA that `services` saved, with one dialog, and starts the
    /// listener. A cancel or an error deletes the files again and leaves
    /// HTTPS off. The marker tells the next launch about an install that the
    /// quit of the app interrupted. It runs inside `httpsSetupTask`.
    private func install(_ ca: LocalCA) async {
        let services = domainTLS
        setHTTPSInstallPending(true)
        let outcome = await Self.blocking { services.install(ca) }
        guard !Task.isCancelled else { return }
        switch outcome {
        case .done:
            tlsCA = ca
            setHTTPSEnabled(true)
            setHTTPSInstallPending(false)
            if domainsEnabled {
                await runHTTPS()
            } else {
                setHTTPSStatus(.init(phase: .off))
            }
        case .cancelled:
            services.removeCAFiles()
            setHTTPSInstallPending(false)
            setHTTPSEnabled(false)
            setHTTPSStatus(.init(phase: .off, problem: "You cancelled the password dialog. HTTPS stays off."))
        case .failed(let status):
            services.removeCAFiles()
            setHTTPSInstallPending(false)
            setHTTPSEnabled(false)
            setHTTPSStatus(.init(phase: .off, problem: "HTTPS could not start: macOS error \(status)."))
        }
    }

    /// Stops HTTPS and removes the CA. The key file goes first, before the
    /// dialog, so the CA can never sign again, even if the user cancels or the
    /// app ends. Then macOS removes the trust (one dialog) and the keychain
    /// certificate. If the files are gone, the certificates with the label of
    /// the CA go instead.
    private func disableHTTPS() {
        let wasOpen = closeDashboardForDialog()
        tearDownHTTPS()
        let ca = tlsCA ?? domainTLS.loadCA()
        tlsCA = nil
        setHTTPSEnabled(false)
        domainTLS.removeCAFiles()
        // The routes forget the names that the certificates served.
        rebuildDomainRoutes()
        removeCertificate(of: ca, restore: wasOpen)
    }

    /// The text of a removal that macOS did not finish.
    nonisolated static let leftoverCAText =
        "macOS still lists the certificate authority and its trust setting. They have no effect, because ColimaBar deleted the key. Delete the certificate \"ColimaBar Local CA\" in Keychain Access."

    /// "Delete Certificate…": a removal that the quit of the app interrupted
    /// leaves the marker. The user clicks, then macOS removes the trust and
    /// the certificates with the label of the CA (one dialog for each).
    func cleanUpLeftoverCA() {
        guard !isDebug, !httpsEnabled, httpsSetupTask == nil, domainStatus.https.offersCleanUp else { return }
        removeCertificate(of: nil, restore: closeDashboardForDialog())
    }

    /// Asks macOS to remove the trust and the certificate of `ca`, or the
    /// certificates with the label of the CA when `ca` is nil. The marker
    /// stays from before the dialog until its outcome. It runs inside
    /// `httpsSetupTask`.
    private func removeCertificate(of ca: LocalCA?, restore wasOpen: Bool) {
        setHTTPSRemovalPending(true)
        setHTTPSStatus(.init(phase: .removing))
        let services = domainTLS
        httpsSetupTask = Task {
            defer {
                httpsSetupTask = nil
                restoreDashboard(ifOpen: wasOpen)
            }
            let outcome = await Self.blocking { ca.map { services.uninstall($0) } ?? services.uninstallLeftovers() }
            guard !Task.isCancelled else { return }
            setHTTPSRemovalPending(false)
            let note: String
            switch outcome {
            case .done:
                note = "ColimaBar removed the certificate authority."
            case .cancelled:
                note = Self.leftoverCAText
            case .failed(let status):
                note =
                    "macOS could not remove the certificate authority (error \(status)). It has no effect, because ColimaBar deleted the key. Delete the certificate \"ColimaBar Local CA\" in Keychain Access."
            }
            setHTTPSStatus(.init(phase: .off, problem: note))
        }
    }

    private func setHTTPSEnabled(_ on: Bool) {
        setHTTPSEnabledFlag(on)
        if !isDebug { domainsStore.set(on, forKey: Defaults.Key.domainsHTTPS.rawValue) }
    }

    /// "Trust Again…": adds the CA to the login keychain and trusts it again.
    /// A CA that does not cover the names of the domains is replaced: macOS
    /// removes the old one (one dialog), then trusts a new one (a second dialog).
    func trustCAAgain() {
        guard !isDebug, httpsEnabled, httpsSetupTask == nil, domainStatus.https.phase == .untrusted,
            let ca = tlsCA ?? domainTLS.loadCA()
        else { return }
        let wasOpen = closeDashboardForDialog()
        let services = domainTLS
        let token = httpsStartToken
        if ca.covers(activeDomainSuffixes) {
            httpsSetupTask = Task {
                defer {
                    httpsSetupTask = nil
                    restoreDashboard(ifOpen: wasOpen)
                }
                let outcome = await Self.blocking { services.install(ca) }
                guard !Task.isCancelled, outcome == .done else { return }
                let trusted = await Self.blocking { services.isTrusted(ca) }
                guard !Task.isCancelled else { return }
                applyHTTPSTrust(trusted, token: token)
            }
        } else {
            reissueCA(old: ca, restore: wasOpen)
        }
    }

    /// Replaces `old` with a CA that covers the active suffixes. The old CA
    /// goes first. If the user cancels that dialog, nothing changes: the old
    /// CA stays installed with its files. If the user cancels the second
    /// dialog, the new files go and HTTPS is off. It never leaves the old files
    /// without the old CA, or a CA in the keychain without its files.
    func reissueCA(old: LocalCA, restore wasOpen: Bool) {
        tearDownHTTPS()
        setHTTPSStatus(.init(phase: .settingUp))
        let services = domainTLS
        let suffixes = activeDomainSuffixes
        httpsSetupTask = Task {
            defer {
                httpsSetupTask = nil
                restoreDashboard(ifOpen: wasOpen)
            }
            let removed = await Self.blocking { services.uninstall(old) }
            guard !Task.isCancelled else { return }
            guard removed == .done else {
                tlsCA = old
                return setHTTPSStatus(
                    .init(
                        phase: .untrusted,
                        problem: "ColimaBar did not replace the certificate authority. "
                            + (old.covers(suffixes) ? Self.keptOldCAText : Self.needsNewCAText)))
            }
            tlsCA = nil
            let prepared = await Self.blocking { Result { try services.prepareCA(permitted: suffixes) } }
            guard !Task.isCancelled else { return }
            guard case .success(let ca) = prepared else {
                services.removeCAFiles()
                setHTTPSEnabled(false)
                return setHTTPSStatus(
                    .init(
                        phase: .off,
                        problem: "HTTPS could not start. ColimaBar could not make the certificate authority."))
            }
            await install(ca)
        }
    }

    /// A change of the custom suffix changes the names that the CA must
    /// permit. A CA that lacks a name stops the listener at once (no old-CA
    /// listener keeps running), then it is replaced like "Trust Again…"
    /// does: two dialogs. A CA that permits a name that is gone is replaced
    /// too, so the CA never covers a suffix without a resolver. A cancel keeps
    /// the old CA. It needs the master switch on, because a dialog must
    /// follow a click. `carried` is true when the caller closed the dashboard
    /// already: this call brings it back, with any outcome.
    func replaceCAForSuffixes(reopening carried: Bool = false) async {
        if await !replaceCAIfNeeded(carried: carried) { restoreDashboard(ifOpen: carried) }
    }

    /// True when a replacement ran: it restores the dashboard itself.
    private func replaceCAIfNeeded(carried: Bool) async -> Bool {
        guard !isDebug, domainsEnabled, httpsEnabled else { return false }
        while let running = httpsSetupTask { await running.value }
        guard httpsEnabled, domainsEnabled, let old = tlsCA ?? domainTLS.loadCA() else { return false }
        tlsCA = old
        let suffixes = activeDomainSuffixes
        if Set(old.permitted) == Set(suffixes) {
            if !domainStatus.https.listening { await startHTTPS() }
            return false
        }
        // Stops a listener whose CA lacks a name, and keeps `.untrusted` with the reason.
        await startHTTPS()
        guard httpsSetupTask == nil, httpsEnabled else { return false }
        // A dashboard that the caller closed stays closed: the new flow restores it.
        let wasOpen = carried || closeDashboardForDialog()
        reissueCA(old: old, restore: wasOpen)
        while let running = httpsSetupTask { await running.value }
        // A cancelled replacement leaves a CA that still covers every name: run with it.
        if httpsEnabled, domainStatus.https.phase == .untrusted, tlsCA?.covers(suffixes) ?? false,
            !domainStatus.https.listening
        {
            await startHTTPS()
        }
        return true
    }

    /// The text for an old CA that stays and still covers every active name.
    nonisolated static let keptOldCAText = "The old one still works for your names."

    /// The text for a CA that does not permit the active suffixes.
    nonisolated static let needsNewCAText =
        "The certificate authority does not cover the current names. Click Trust Again to make a new one."

    /// Shows `ca.pem` in Finder, for tools with their own trust store.
    func showCACertificate() {
        let path = domainTLS.certificatePath
        guard !path.isEmpty, FileManager.default.fileExists(atPath: path) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    /// True while the CA exists: the switch is on, or a start is running.
    var caExists: Bool { httpsEnabled }

    // MARK: - Listener

    /// The launch calls it once. It cleans up an install that the app did not
    /// finish, offers the clean-up of a removal that the app did not finish,
    /// and starts the listener for a launch with the setting on. It shows no
    /// dialog. The clean-up runs inside `httpsSetupTask`, so a switch cannot
    /// start a second one.
    func startHTTPSAtLaunch() {
        guard !isDebug, httpsSetupTask == nil else { return }
        if httpsRemovalPending, !httpsEnabled {
            setHTTPSStatus(.init(phase: .off, problem: Self.leftoverCAText, offersCleanUp: true))
        }
        let recovery: Task<Void, Never>? = httpsInstallPending ? Task { await recoverPendingInstall() } : nil
        httpsSetupTask = recovery
        Task {
            if let recovery {
                await recovery.value
                httpsSetupTask = nil
            }
            await resumeHTTPS()
        }
    }

    /// A change of the master switch calls it: start the listener if the settings ask for it.
    func resumeHTTPS() async {
        guard domainsEnabled, httpsEnabled, httpsSetupTask == nil else { return }
        await runHTTPS(retryFirst: true)
    }

    /// The app ended while the password dialog showed. If macOS holds trust
    /// settings for the saved CA, the install finished: keep it and turn
    /// HTTPS on. Else delete the files and the certificate. Neither path
    /// calls `uninstall`: a launch shows no dialog, and a certificate
    /// without trust settings needs none.
    private func recoverPendingInstall() async {
        guard httpsInstallPending else { return }
        guard !httpsEnabled else { return setHTTPSInstallPending(false) }
        let services = domainTLS
        let keep = await Self.blocking { () -> Bool in
            guard let ca = services.loadCA() else {
                services.removeCAFiles()
                return false
            }
            if services.hasTrustSettings(ca) { return true }
            services.deleteCertificate(ca)
            services.removeCAFiles()
            return false
        }
        guard !Task.isCancelled else { return }
        if keep { setHTTPSEnabled(true) }
        setHTTPSInstallPending(false)
    }

    /// Starts the listener again, for a retry, a move or a wake. It does nothing while a setup runs.
    func startHTTPS(retryFirst: Bool = false) async {
        guard httpsSetupTask == nil else { return }
        await runHTTPS(retryFirst: retryFirst)
    }

    /// Loads the CA, makes the identity provider, starts the TLS listener and
    /// tests it. It falls back to one certificate for all names if the
    /// per-name certificates fail the test. A missing trust only sets the
    /// `.untrusted` phase. A CA that does not cover the active suffixes starts
    /// no listener (`needsNewCAText`). It shows no dialog. A listener that runs
    /// keeps its status and links until the new port is bound.
    private func runHTTPS(retryFirst: Bool = false) async {
        guard !isDebug, domainsEnabled, httpsEnabled else { return }
        httpsStartToken += 1
        let token = httpsStartToken
        httpsRetry?.cancel()
        httpsRetry = nil
        multiSANTask?.cancel()
        multiSANTask = nil
        multiSANRenewTask?.cancel()
        multiSANRenewTask = nil
        httpsStartPublished = domainBlockedPorts
        if !(domainStatus.https.listening && domainProxy.httpsPort != nil) {
            setHTTPSStatus(.init(phase: .settingUp))
        }
        domainProxy.onHTTPSListenerFailure = { [weak self] in
            Task { @MainActor in self?.httpsListenerFailed(token: token) }
        }
        guard let ca = tlsCA ?? domainTLS.loadCA() else {
            return setHTTPSFailed(
                "HTTPS could not start. The certificate authority files are missing or invalid. Turn HTTPS off and on.",
                retry: false)
        }
        tlsCA = ca
        let suffixes = activeDomainSuffixes
        guard ca.covers(suffixes) else {
            domainProxy.stopHTTPS()
            return setHTTPSStatus(.init(phase: .untrusted, problem: Self.needsNewCAText))
        }
        guard let provider = await ensureTLSProvider(ca: ca) else {
            guard token == httpsStartToken else { return }
            return setHTTPSFailed("HTTPS could not start. The TLS identity test failed.")
        }
        guard token == httpsStartToken, domainsEnabled, httpsEnabled else { return }
        let proxy = domainProxy
        let cache = LeafCache(
            ca: ca, provider: provider, suffixes: suffixes,
            resolves: { proxy.routes.routeHost(for: $0) })
        // The old cache may still serve until the new listener runs. Its keys go when this start ends.
        let previous = leafCache
        defer { previous?.discardAll() }
        leafCache = cache
        tlsMode = .perSNI
        guard var port = await listenHTTPS(cache: cache, mode: .perSNI, token: token, retryFirst: retryFirst) else {
            return
        }
        if await !domainTLS.selfTest(port: port, ca: ca, suffixes: suffixes) {
            guard token == httpsStartToken else { return }
            log.error("the HTTPS self-test failed with a certificate for each name")
            tlsMode = .multiSAN
            guard let again = await listenHTTPS(cache: cache, mode: .multiSAN, token: token, retryFirst: false)
            else { return }
            cache.dropMultiSAN(except: multiSANEpoch)
            port = again
            guard await domainTLS.selfTest(port: port, ca: ca, suffixes: suffixes) else {
                guard token == httpsStartToken else { return }
                domainProxy.stopHTTPS()
                return setHTTPSFailed("HTTPS could not start. The HTTPS self-test failed.")
            }
        }
        let services = domainTLS
        let trusted = await Self.blocking { services.isTrusted(ca) }
        guard token == httpsStartToken else { return }
        httpsRetryCount = 0
        httpsTrustCheckedAt = Date()
        setHTTPSStatus(.init(phase: trusted ? .running : .untrusted, port: port))
        if tlsMode == .multiSAN { scheduleMultiSANRenewal(token: token) }
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
        if mode == .multiSAN { multiSANEpoch += 1 }
        let server = DomainTLSServer(cache: cache, mode: mode, names: names, epoch: multiSANEpoch)
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
            for relative in domainRoutes.rememberedNames {
                let host = DomainLink.host(relative: relative, suffix: suffix)
                names += [host, "*.\(host)"]
            }
        }
        return Array(Set(names)).sorted()
    }

    /// In the fallback mode, the certificate lists the names. When the routes
    /// change, wait 2 s, then start the listener again with a new certificate.
    /// The fallback is best effort: a browser may not accept `*.localhost`,
    /// and a name that a container gets after the change waits for the new certificate.
    func syncMultiSANLeaf() {
        guard !isDebug, httpsEnabled, httpsSetupTask == nil, tlsMode == .multiSAN, domainStatus.https.listening,
            let cache = leafCache, let ca = tlsCA, multiSANNames() != multiSANServed
        else { return }
        multiSANTask?.cancel()
        let token = httpsStartToken
        multiSANTask = Task {
            try? await Task.sleep(for: .seconds(domainTimings.multiSANDebounce))
            guard !Task.isCancelled, token == httpsStartToken, domainStatus.https.listening else { return }
            await relistenMultiSAN(cache: cache, ca: ca, token: token)
        }
    }

    /// The certificate of the fallback mode lives 30 days. A new one is made
    /// before the old one is in its renewal window, so a long run never serves an expired one.
    private func scheduleMultiSANRenewal(token: Int) {
        multiSANRenewTask?.cancel()
        multiSANRenewTask = Task {
            try? await Task.sleep(for: .seconds(domainTimings.multiSANRenew))
            guard !Task.isCancelled, token == httpsStartToken, httpsEnabled, domainsEnabled,
                domainStatus.https.listening, let cache = leafCache, let ca = tlsCA
            else { return }
            // A new epoch makes a new certificate. The old one goes after the new listener runs.
            await relistenMultiSAN(cache: cache, ca: ca, token: token)
            guard !Task.isCancelled, token == httpsStartToken else { return }
            scheduleMultiSANRenewal(token: token)
        }
    }

    /// Starts the listener of the fallback mode again and tests it. Each wait
    /// checks the token and the status again, so a stop or a new start wins.
    private func relistenMultiSAN(cache: LeafCache, ca: LocalCA, token: Int) async {
        guard let port = await listenHTTPS(cache: cache, mode: .multiSAN, token: token, retryFirst: false),
            token == httpsStartToken
        else { return }
        let passed = await domainTLS.selfTest(port: port, ca: ca, suffixes: activeDomainSuffixes)
        guard !Task.isCancelled, token == httpsStartToken, httpsEnabled, domainsEnabled else { return }
        guard passed else {
            domainProxy.stopHTTPS()
            return setHTTPSFailed("HTTPS could not start. The HTTPS self-test failed.")
        }
        cache.dropMultiSAN(except: multiSANEpoch)
        var https = domainStatus.https
        guard https.listening else { return }
        https.port = port
        setHTTPSStatus(https)
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
        multiSANRenewTask?.cancel()
        multiSANRenewTask = nil
    }

    /// Quit: stops every task of HTTPS, also a setup that waits for a dialog,
    /// and deletes the temporary keychain. A cancelled setup changes no state, and
    /// the marker of an install tells the next launch what to clean up.
    func stopHTTPSForQuit() {
        invalidateHTTPSTasks()
        httpsSetupTask?.cancel()
        tlsProvider?.removeAll()
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
        setHTTPSFailed("The HTTPS listener stopped. ColimaBar tries again soon.")
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
        guard !isDebug, domainsEnabled, httpsEnabled, httpsSetupTask == nil, domainStatus.https.listening,
            httpsRebindGapPassed()
        else { return }
        httpsRebindAt = Date()
        // The listener holds a port that a container publishes: the links must not name it while the new one binds.
        setHTTPSStatus(.init(phase: .settingUp))
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

    /// After a wake: unlock the temporary keychain, check the trust, and start the listener if it is gone.
    func httpsAfterWake() {
        guard !isDebug, domainsEnabled, httpsEnabled, httpsSetupTask == nil else { return }
        tlsProvider?.unlockIfNeeded()
        let phase = domainStatus.https.phase
        guard phase != .settingUp, phase != .removing else { return }
        if domainProxy.httpsPort == nil {
            Task { await startHTTPS() }
        } else {
            refreshHTTPSTrust(minGap: 0)
            moveHTTPSBackToFirstPort()
        }
    }

    /// The heartbeat calls it. It checks the trust at most once in `trustRecheck`. A
    /// listener on 8443 looks for a free port 443, at most once in a rebind gap.
    func httpsHeartbeat() {
        guard !isDebug, domainsEnabled, httpsEnabled, httpsSetupTask == nil, domainStatus.https.listening else {
            return
        }
        refreshHTTPSTrust(minGap: domainTimings.trustRecheck)
        guard domainStatus.https.usesFallback, Date().timeIntervalSince(httpsMoveBackAt) >= domainTimings.rebindGap
        else { return }
        moveHTTPSBackToFirstPort()
    }

    /// Asks macOS again if it trusts the CA, off the main actor, when the last
    /// check is `minGap` seconds old. The user can remove the trust in
    /// Keychain Access at any time.
    func refreshHTTPSTrust(minGap: TimeInterval) {
        guard !isDebug, httpsEnabled, domainStatus.https.listening, !httpsTrustChecking, let ca = tlsCA,
            Date().timeIntervalSince(httpsTrustCheckedAt) >= minGap
        else { return }
        httpsTrustChecking = true
        httpsTrustCheckedAt = Date()
        let token = httpsStartToken
        let services = domainTLS
        Task {
            let trusted = await Self.blocking { services.isTrusted(ca) }
            httpsTrustChecking = false
            applyHTTPSTrust(trusted, token: token)
        }
    }

    /// Sets `.running` or `.untrusted` from a trust check, if the listener
    /// still runs and no newer start has begun.
    private func applyHTTPSTrust(_ trusted: Bool, token: Int) {
        guard token == httpsStartToken, httpsEnabled, domainStatus.https.listening else { return }
        var https = domainStatus.https
        let phase: DomainStatus.HTTPS.Phase = trusted ? .running : .untrusted
        guard https.phase != phase else { return }
        https.phase = phase
        setHTTPSStatus(https)
    }

    /// The line in the diagnostics file. It holds the state and counts, no names.
    var httpsStatusText: String {
        guard httpsEnabled else { return "off" }
        let https = domainStatus.https
        let phase: String
        let trust: String
        switch https.phase {
        case .off: (phase, trust) = ("off", "unknown")
        case .settingUp: (phase, trust) = ("starting", "unknown")
        case .removing: (phase, trust) = ("removing", "unknown")
        case .failed: (phase, trust) = ("failed", "unknown")
        case .running: (phase, trust) = ("listening on port \(https.port.map(String.init) ?? "?")", "yes")
        case .untrusted:
            (phase, trust) = (https.port.map { "listening on port \($0)" } ?? "not listening", "no")
        }
        let mode = tlsMode == .perSNI ? "a certificate for each name" : "one certificate"
        return
            "\(phase), identity: \(tlsProvider?.name ?? "none"), \(mode), leaves made: \(leafCache?.mintedCount ?? 0), CA trusted: \(trust)"
    }
}
