import AppKit
import OSLog

/// `colimabar://` links. The design is in ARCHITECTURE.md, section Links.
extension AppDelegate {
    nonisolated private static let linkLog = Logger(category: "links")

    // MARK: - Delivery

    /// Installs the handler for `kAEGetURL`. It runs first in
    /// applicationWillFinishLaunching: AppKit sends the launch event between
    /// will- and didFinishLaunching. The handler only queues the link.
    /// `application(_:open:)` is not used, because it also gets file opens.
    func installLinkHandler() {
        NSAppleEventManager.shared().setEventHandler(
            self, andSelector: #selector(handleGetURL(_:withReplyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
    }

    @objc private func handleGetURL(_ event: NSAppleEventDescriptor, withReplyEvent reply: NSAppleEventDescriptor) {
        guard let text = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue else {
            Self.linkLog.error("a link event had no text")
            return
        }
        links.receive(text)
    }

    /// Ends the launch: takes the links of a handoff, registers the scheme and
    /// starts to handle the links that wait.
    func startLinks() {
        if !Self.isDebugRun {
            let stored = Defaults.dictionary(.linkHandoff)
            if stored != nil { Defaults.remove(.linkHandoff) }
            for text in LinkInbox.handoff(stored, now: Date().timeIntervalSince1970) { links.receive(text) }
            registerURLScheme()
        }
        links.open { [weak self] text in await self?.handle(link: text) }
    }

    /// An in-app update restarts the app through launchd, not LaunchServices,
    /// so a new scheme could stay unregistered. An installed copy registers
    /// itself, off the main actor.
    private func registerURLScheme() {
        guard LoginItem.isInstalled(Bundle.main.bundlePath) else { return }
        let url = Bundle.main.bundleURL
        Task.detached {
            let status = LSRegisterURL(url as CFURL, true)
            if status == noErr {
                Self.linkLog.notice("registered the URL scheme")
            } else {
                Self.linkLog.error("could not register the URL scheme (status \(status, privacy: .public))")
            }
        }
    }

    /// What happened to links that this copy gave to another copy.
    enum ForwardResult: Equatable {
        case nothing
        case forwarded
        /// The open request failed or took more than 2 s.
        case failed
    }

    /// A second copy that LaunchServices started for a link gives the links to
    /// the running copy. Links that arrive while it waits go in the next round
    /// (3 rounds at most). Each round waits up to 2 s for the open request.
    /// If a request fails, the caller reopens the running copy, so the user
    /// at least sees the dashboard.
    func forwardLinks(to app: URL) -> ForwardResult {
        var result = ForwardResult.nothing
        for _ in 0..<3 {
            let round = forward(links.takeAll(), to: app)
            if round == .nothing { break }
            if result != .failed { result = round }
        }
        return result
    }

    /// Gives these link texts to the copy at `app`.
    func forward(_ texts: [String], to app: URL) -> ForwardResult {
        let (urls, dropped) = LinkInbox.urls(from: texts)
        if dropped > 0 { Self.linkLog.error("\(dropped, privacy: .public) links were no URL and are dropped") }
        guard !urls.isEmpty else { return .nothing }
        let done = LinkForward()
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = false
        NSWorkspace.shared.open(urls, withApplicationAt: app, configuration: cfg) { _, error in
            if let error {
                Self.linkLog.error("could not forward links: \(error.localizedDescription, privacy: .public)")
            }
            let failed = error != nil
            Task { @MainActor in done.finish(failed: failed) }
        }
        let deadline = Date().addingTimeInterval(2)
        while !done.finished, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        if !done.finished { Self.linkLog.error("forwarding links took too long") }
        return done.finished && !done.failed ? .forwarded : .failed
    }

    /// Writes the held links for the login agent, like `revealOnLaunch`.
    /// Returns the stamp of the handoff, or nil if there was nothing to write.
    /// The caller removes the handoff again if the agent does not start. The
    /// links stay held for that case.
    func handOffLinks() -> Double? {
        let held = links.pending
        guard !held.isEmpty else { return nil }
        let now = Date().timeIntervalSince1970
        Defaults.set(LinkInbox.handoffValue(held, now: now), .linkHandoff)
        CFPreferencesAppSynchronize(kCFPreferencesCurrentApplication)
        return now
    }

    /// The agent did not start. Takes the handoff back and keeps the links
    /// here. If the agent took the handoff in the meantime (a slow start), it
    /// handles the links, so this copy drops its own.
    func takeBackHandoff(stamp: Double) {
        CFPreferencesAppSynchronize(kCFPreferencesCurrentApplication)
        if LinkInbox.handoffIsStillMine(Defaults.dictionary(.linkHandoff), stamp: stamp) {
            Defaults.remove(.linkHandoff)
        } else {
            let n = links.takeAll().count
            Self.linkLog.notice("the agent took the links; this copy drops \(n, privacy: .public)")
        }
    }

    // MARK: - Handling

    private func handle(link text: String) async {
        switch AppLink.parse(text) {
        case .failure(let failure):
            Self.linkLog.notice("link refused: \(failure.kind, privacy: .public)")
            tell(AppLinkPolicy.text(for: failure), about: text, kind: failure.kind)
        case .success(let link):
            Self.linkLog.notice("link: \(link.route, privacy: .public)")
            switch link {
            case .open:
                revealDashboard(afterLaunch: Date().timeIntervalSince(launchedAt) < 2)
            case .doctor:
                ui.showDoctor = true
                revealDashboard(afterLaunch: Date().timeIntervalSince(launchedAt) < 2)
            case .vm(let action, let profile):
                await run(action, profile: profile ?? model.profile, link: link, text: text)
            }
        }
    }

    private func run(_ action: AppLink.VMAction, profile p: String, link: AppLink, text: String) async {
        Self.linkLog.notice("link profile: \(p, privacy: .private)")
        guard await check(action, profile: p, text: text) else { return }
        if AppLinkPolicy.asks(link, setting: model.askBeforeLinks) {
            links.isAsking = true
            let answer = LinkAlert.confirm(action, profile: p, model: model)
            links.isAsking = false
            guard answer.confirmed else { return }
            if answer.stopAsking { model.askBeforeLinks = false }
            // The state can change while the question is open.
            guard await check(action, profile: p, text: text) else { return }
        }
        model.run(action.ctl, profile: p)
    }

    /// Reads the profiles, then applies the gates. Returns true if the link
    /// may run. A refusal sends one notification; a no-op only logs.
    private func check(_ action: AppLink.VMAction, profile p: String, text: String) async -> Bool {
        var facts = AppLinkPolicy.Facts(updating: relaunching || model.updateRestarting)
        if !facts.updating {
            var listed = await model.refreshStatus()
            if AppLinkPolicy.needsSecondRead(listed: listed, colimaMissing: model.state == .notInstalled) {
                listed = await model.refreshStatus()
            }
            facts = AppLinkPolicy.facts(
                profile: p, profiles: model.profiles, updating: relaunching || model.updateRestarting,
                colimaMissing: model.state == .notInstalled, listed: listed, busyMarker: model.busyMarker(of: p))
        }
        switch AppLinkPolicy.decide(action, facts) {
        case .run:
            return true
        case .nothing:
            Self.linkLog.notice("link has nothing to do")
            return false
        case .refuse(let refusal):
            Self.linkLog.notice("link refused: \(String(describing: refusal), privacy: .public)")
            tell(
                AppLinkPolicy.text(for: refusal, action: action, profile: p), about: text,
                kind: String(describing: refusal))
            return false
        }
    }

    /// One message for each link text and kind per minute, and 5 per minute
    /// in all. It goes out as a notification. If notifications are off, the
    /// notification is silent, so an alert window shows the text. Both
    /// ways record the text for the dashboard list of alerts.
    private func tell(_ body: String, about text: String, kind: String) {
        guard links.allowsNotice(for: text, kind: kind) else { return }
        Notifier.shared.post(body, record: true)
        if AppLinkPolicy.channel(notificationsAllowed: model.notificationsAllowed) == .alert {
            links.isAsking = true
            LinkAlert.inform(body, model: model)
            links.isAsking = false
        }
    }
}

/// A flag that the open request sets when it ends (see `forward`).
@MainActor
private final class LinkForward {
    var finished = false
    var failed = false

    func finish(failed: Bool) {
        self.failed = failed
        finished = true
    }
}
