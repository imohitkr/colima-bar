import Foundation

/// The custom suffix of container domains, for example `colima.internal`.
/// ColimaBar runs a small DNS server (`DNSResponder`) and writes
/// `/etc/resolver/<suffix>` (`ResolverInstaller`, one administrator prompt) so
/// that macOS sends the names of the suffix to it. A debug run runs no server
/// and writes no file. The master switch off stops the server but keeps the
/// file; only turning the suffix off removes it. The root shell, the DNS
/// server, the checks and the port test sit behind seams, so a test never
/// reaches `osascript`, `/etc` or a real DNS port.
extension ColimaModel {
    nonisolated static let dnsPortRange = 20000..<32768

    /// A random port that `isFree` accepts, or nil after 50 tries.
    nonisolated static func pickDNSPort(isFree: (Int) -> Bool) -> Int? {
        for _ in 0..<50 {
            let port = Int.random(in: dnsPortRange)
            if isFree(port) { return port }
        }
        return nil
    }

    func setDNSStatus(_ dns: DomainStatus.DNS) {
        var status = domainStatus
        status.dns = dns
        setDomainStatus(status)
    }

    /// The saved port of the resolver file, if it is a valid one.
    var storedDNSPort: Int? {
        (domainsStore.object(forKey: Defaults.Key.domainDNSPort.rawValue) as? Int)
            .flatMap { ResolverFile.portRange.contains($0) ? $0 : nil }
    }

    /// The text of the caption under the suffix field.
    var domainSuffixCaption: String? {
        let first = domainRoutes.routes.keys.sorted().first
        let example = first.flatMap { name in domainSuffix.map { DomainLink.host(relative: name, suffix: $0) } }
        return domainStatus.dns.caption(suffix: domainSuffix, example: example)
    }

    /// The line in the diagnostics file. The suffix is the user's own choice, not a secret.
    var domainSuffixStatusText: String {
        guard let suffix = domainSuffix else { return "not set" }
        let dns = domainStatus.dns
        let phase: String
        switch dns.phase {
        case .off: phase = "off"
        case .applying: phase = "writing the resolver file"
        case .running: phase = "running"
        case .notUsedYet: phase = "running, macOS does not use the file yet"
        case .failed: phase = "failed"
        }
        return "\(suffix), DNS port \(dns.port.map(String.init) ?? "none"), \(phase)"
    }

    private func noting(_ dns: DomainStatus.DNS, _ note: String) -> DomainStatus.DNS {
        var copy = dns
        copy.note = note
        return copy
    }

    // MARK: - Server

    func invalidateDNSTasks() {
        dnsStartToken += 1
        dnsRetry?.cancel()
        dnsRetry = nil
        dnsRecheck?.cancel()
        dnsRecheck = nil
    }

    /// The master switch off, or a stop: no server. The resolver file stays.
    /// A write of the resolver file that runs keeps its `.applying` state: its
    /// flow ends it.
    func stopDNSResponder() {
        invalidateDNSTasks()
        dnsResponder.stop()
        if domainStatus.dns.phase != .applying { setDNSStatus(DomainStatus.DNS()) }
    }

    /// Starts the server on the saved port, if the resolver file is ours and
    /// names that port. Then it asks the system resolver (`verifyResolver`).
    /// It shows no dialog, and it waits while a write of the file runs.
    func startDNSResponder() async {
        guard !isDebug, domainsEnabled, let suffix = domainSuffix, domainStatus.dns.phase != .applying else { return }
        dnsStartToken += 1
        let token = dnsStartToken
        dnsRetry?.cancel()
        dnsRetry = nil
        dnsResponder.onFailure = { [weak self] in
            Task { @MainActor in self?.dnsListenerFailed(token: token) }
        }
        guard let port = storedDNSPort else {
            dnsResponder.stop()
            return setDNSFailed("The DNS port is missing. Click Repair to choose a new one.", retry: false)
        }
        guard ResolverInstaller.inspect(suffix, dir: resolverDir) == .ours else {
            dnsResponder.stop()
            return setDNSFailed(
                "The file /etc/resolver/\(suffix) is missing or changed. Click Repair to write it again.", retry: false
            )
        }
        guard ResolverInstaller.port(suffix, dir: resolverDir) == port else {
            dnsResponder.stop()
            return setDNSFailed(
                "The file /etc/resolver/\(suffix) names another port. Click Repair to write it again.", retry: false)
        }
        dnsResponder.zone = suffix
        let ok = await dnsResponder.start(port: UInt16(port))
        guard token == dnsStartToken, domainsEnabled, !isDebug else { return }
        if ok {
            setDNSStatus(DomainStatus.DNS(phase: .running, port: UInt16(port)))
            await verifyResolver()
        } else {
            setDNSFailed("The DNS server could not start on port \(port).")
        }
    }

    private func setDNSFailed(_ problem: String, retry: Bool = true) {
        setDNSStatus(DomainStatus.DNS(phase: .failed, problem: problem))
        dnsRetry?.cancel()
        dnsRetry = nil
        guard retry else { return }
        let token = dnsStartToken
        let delay = domainTimings.failureRetry
        dnsRetry = Task {
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, token == dnsStartToken, domainStatus.dns.phase == .failed else { return }
            dnsRetry = nil
            await startDNSResponder()
        }
    }

    private func dnsListenerFailed(token: Int) {
        guard !isDebug, domainsEnabled, token == dnsStartToken, domainStatus.dns.phase != .applying else { return }
        dnsStartToken += 1
        setDNSFailed("The DNS server stopped. ColimaBar tries again soon.")
    }

    /// The listener normally survives a sleep. Start it again if it is gone.
    /// Then ask the system resolver again: a wake can change what it does with the file.
    func dnsAfterWake() {
        guard !isDebug, domainsEnabled, domainSuffix != nil, domainStatus.dns.phase != .applying else { return }
        Task {
            if dnsResponder.port == nil {
                await startDNSResponder()
            } else {
                await verifyResolver()
            }
        }
    }

    /// Checks the system resolver. While macOS does not use the file yet
    /// (`.notUsedYet`), it checks again after each wait of
    /// `DomainTimings.dnsRecheck`, because macOS can need a few seconds to read a new file.
    func verifyResolver() async {
        dnsRecheck?.cancel()
        dnsRecheck = nil
        await checkResolver()
        guard domainStatus.dns.phase == .notUsedYet else { return }
        let token = dnsStartToken
        let waits = domainTimings.dnsRecheck
        dnsRecheck = Task {
            for wait in waits {
                try? await Task.sleep(for: .seconds(wait))
                guard !Task.isCancelled, token == dnsStartToken, domainStatus.dns.phase == .notUsedYet else { return }
                await checkResolver()
            }
        }
    }

    /// Looks up a name of the suffix through the system resolver. It sets
    /// `.running`, or `.notUsedYet` when macOS does not use the file yet.
    func checkResolver() async {
        guard let suffix = domainSuffix, dnsResponder.port != nil else { return }
        let ok = await resolverCheck("\(DomainName.selfTestLabel).\(suffix)")
        let phase = domainStatus.dns.phase
        guard suffix == domainSuffix, phase == .running || phase == .notUsedYet else { return }
        var dns = domainStatus.dns
        dns.phase = ok ? .running : .notUsedYet
        dns.problem = nil
        setDNSStatus(dns)
    }

    // MARK: - Apply, remove, repair

    /// Sets or changes the suffix: one administrator prompt writes the new
    /// file and removes the old one. With HTTPS on, a new CA follows.
    func applySuffix(_ raw: String) async {
        guard !isDebug, domainsEnabled, domainStatus.dns.phase != .applying else { return }
        let suffix = DomainSuffix.normalized(raw)
        guard DomainSuffix.problem(suffix) == nil, suffix != domainSuffix else { return }
        let before = domainStatus.dns
        if ResolverInstaller.precheck(suffix, dir: resolverDir) == .foreign {
            return setDNSStatus(
                noting(before, "The file /etc/resolver/\(suffix) belongs to another tool. Choose another suffix."))
        }
        guard let port = storedDNSPort ?? Self.pickDNSPort(isFree: dnsPortFree) else {
            return setDNSStatus(noting(before, "ColimaBar found no free port for the DNS server."))
        }
        dismissPopover()
        setDNSStatus(DomainStatus.DNS(phase: .applying))
        let old = domainSuffix
        let outcome = await ResolverInstaller.apply(
            new: suffix, old: old, port: port, dir: resolverDir, run: resolverRun)
        guard await finishResolverWrite(outcome, before: before, suffix: suffix) else { return }
        domainsStore.set(suffix, forKey: Defaults.Key.domainSuffix.rawValue)
        domainsStore.set(port, forKey: Defaults.Key.domainDNSPort.rawValue)
        setDomainSuffixValue(suffix)
        setDNSStatus(DomainStatus.DNS())
        rebuildDomainRoutes()
        await startDNSResponder()
        // The CA must permit the new suffix. With HTTPS on, this asks to replace it.
        if httpsEnabled { await replaceCAForSuffixes() }
    }

    /// Turns the suffix off: one administrator prompt removes the file. A cancel keeps the state.
    func removeSuffix() async {
        guard !isDebug, let old = domainSuffix, domainStatus.dns.phase != .applying else { return }
        let before = domainStatus.dns
        dismissPopover()
        setDNSStatus(DomainStatus.DNS(phase: .applying))
        let outcome = await ResolverInstaller.apply(new: nil, old: old, port: 0, dir: resolverDir, run: resolverRun)
        guard await finishResolverWrite(outcome, before: before, suffix: old) else { return }
        invalidateDNSTasks()
        dnsResponder.stop()
        domainsStore.removeObject(forKey: Defaults.Key.domainSuffix.rawValue)
        domainsStore.removeObject(forKey: Defaults.Key.domainDNSPort.rawValue)
        setDomainSuffixValue(nil)
        setDNSStatus(DomainStatus.DNS())
        rebuildDomainRoutes()
        // The CA must never cover a suffix whose resolver is gone.
        if httpsEnabled { await replaceCAForSuffixes() }
    }

    /// Picks a new port for the server and writes the resolver file again.
    func repairDNS() async {
        guard !isDebug, domainsEnabled, let suffix = domainSuffix else { return }
        let phase = domainStatus.dns.phase
        guard phase == .failed || phase == .notUsedYet else { return }
        let before = domainStatus.dns
        if ResolverInstaller.precheck(suffix, dir: resolverDir) == .foreign {
            return setDNSStatus(
                noting(
                    before,
                    "The file /etc/resolver/\(suffix) belongs to another tool. Turn the suffix off and choose another.")
            )
        }
        guard let port = Self.pickDNSPort(isFree: dnsPortFree) else {
            return setDNSStatus(noting(before, "ColimaBar found no free port for the DNS server."))
        }
        dismissPopover()
        setDNSStatus(DomainStatus.DNS(phase: .applying))
        let outcome = await ResolverInstaller.apply(
            new: suffix, old: nil, port: port, dir: resolverDir, run: resolverRun)
        guard await finishResolverWrite(outcome, before: before, suffix: suffix) else { return }
        domainsStore.set(port, forKey: Defaults.Key.domainDNSPort.rawValue)
        invalidateDNSTasks()
        dnsResponder.stop()
        setDNSStatus(DomainStatus.DNS())
        await startDNSResponder()
    }

    /// Shows the note of a cancel, a refusal or an error and restores the old state. True for `.done`.
    private func finishResolverWrite(_ outcome: ResolverInstaller.Outcome, before: DomainStatus.DNS, suffix: String)
        async -> Bool
    {
        // The master switch can go off during the prompt. The server is off then.
        let before = domainsEnabled ? before : DomainStatus.DNS()
        switch outcome {
        case .done:
            return true
        case .cancelled:
            setDNSStatus(noting(before, "You cancelled the password dialog. Nothing changed."))
        case .foreign:
            setDNSStatus(
                noting(before, "The file /etc/resolver/\(suffix) belongs to another tool. Choose another suffix."))
        case .failed(let text):
            setDNSStatus(noting(before, "ColimaBar could not write the resolver file: \(text)"))
        }
        return false
    }
}
