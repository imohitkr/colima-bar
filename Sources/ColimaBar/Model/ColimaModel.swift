import AppKit
import Foundation
import Observation
import os

/// Single source of truth for the dashboard. Every property is only assigned
/// when its value actually changed, so SwiftUI redraws just the cells whose
/// text differs and nothing shifts while the popover is open.
///
/// Container data comes straight from the Docker Engine API on the selected
/// profile's socket (no process per refresh, streaming stats). Colima itself
/// has no API, so VM facts come from `colima list -j`, run only when the VM
/// goes up/down, when a watched Colima directory changes, when the dashboard
/// opens and the last list is over a minute old, or when the last list is
/// over 5 minutes old.
@MainActor @Observable
final class ColimaModel {
    private(set) var state: VMState = .unknown {
        didSet {
            if state != oldValue {
                wakeHeartbeat()
                rebuildDomainRoutes()
            }
        }
    }
    private(set) var busy: String?
    private(set) var vm = VMInfo()
    /// The colima.yaml of the selected profile, or nil when the file is
    /// missing. For a stopped VM, `vm` shows the last start, not this file.
    private(set) var config: VMConfig?
    /// The VM settings that the advanced editor shows, from the same file.
    private(set) var vmSettings: VMSettings.Read?
    /// The SHA-256 of that file. `applyVMSettings` compares it with the file
    /// at Apply, to find an edit made outside ColimaBar.
    private(set) var vmSettingsSHA: String?
    /// True after a check of this VM start found no `ip_address`, so the
    /// refresh does not ask again.
    private var addressUnavailable = false
    private(set) var containers: [Container] = [] {
        didSet { updateDerivedLists() }
    }
    private(set) var stats: [String: Stat] = [:]  // by container id
    private(set) var cpuHistory: [Double] = []  // % of VM CPU used by containers
    private(set) var memHistory: [Double] = []  // % of VM memory used by containers
    private(set) var df: [DFRow] = []
    private(set) var images: [ImageRow] = []
    private(set) var volumes: [VolumeRow] = []
    /// The rows of the Cleanup page, from the same /system/df call as `df`.
    private(set) var cleanup = CleanupReport.empty
    /// The size of the json log file of each container, by full ID, from the
    /// last check. Nil before the first check.
    private(set) var logSizes: [String: Int64]?
    /// The log rows, from `cleanup` and `logSizes`. Updated when either changes.
    private(set) var logItems = CleanupReport.Section()
    private(set) var logSizesChecking = false
    /// Why the last log check gave no sizes, or nil.
    private(set) var logSizesError: String?
    /// The disk image of the selected profile on the Mac. Nil when unknown.
    private(set) var diskImage: DiskImageSize?
    /// A Return Free Space run that ColimaBar started runs now.
    private(set) var isTrimming = false
    /// The last weekly cleanup of each profile (`Defaults.Key.scheduledPruneLastRun`).
    private(set) var pruneLastRun: [String: Date] = PruneSchedule.decode(Defaults.dictionary(.scheduledPruneLastRun))
    /// Weekly cleanup of dangling images and build cache. Off by default.
    var scheduledPrune = Defaults.bool(.scheduledPrune) ?? false {
        didSet {
            guard scheduledPrune != oldValue else { return }
            Defaults.set(scheduledPrune, .scheduledPrune)
            // A new start of the setting begins with no wait.
            if !scheduledPrune { pruneRetryAt = [:] }
        }
    }
    /// Check the registries for newer images once a day (`ColimaModel+ImageUpdates`).
    /// Off by default. It is saved in `domainsStore`, like the other settings
    /// that a test must not persist.
    var imageUpdateCheck = false {
        didSet {
            guard imageUpdateCheck != oldValue else { return }
            // A debug run never writes a setting.
            if !isDebug { domainsStore.set(imageUpdateCheck, forKey: Defaults.Key.imageUpdateCheck.rawValue) }
            imageUpdateSettingChanged()
        }
    }
    /// The image updates of the selected profile, for the badges and the strip.
    private(set) var imageUpdates = ImageUpdateState()
    private(set) var profiles: [ProfileRow] = []
    /// VM actions that run for profiles other than the selected one, by
    /// profile: the busy label, for example "Starting". The profile menu
    /// shows them. The selected profile uses `busy`.
    private(set) var profileActions: [String: String] = [:]
    private(set) var routing = Routing.Status()
    /// The last Doctor run (see ColimaModel+Doctor), or nil before the first.
    private(set) var doctorReport: DoctorReport?
    /// A Doctor check or fix runs now.
    private(set) var isDoctorRunning = false
    /// The keys (`profile/name`) of the Compose projects with a `docker compose` run now.
    private(set) var composeBusy: Set<String> = []
    /// The keys of the projects whose folder or files are gone. It changes
    /// after each container refresh, so a render does not read the disk.
    private(set) var composeMissing: Set<String> = []
    /// True if the docker tool is not on the search path.
    private(set) var composeNoDocker = false
    /// The last lines that `docker compose` printed, for each project key. In
    /// memory only: the output can name values of the project.
    private(set) var composeOutput: [String: [String]] = [:]
    /// The last invalid `debugShellImage` value that ColimaBar told the user about.
    @ObservationIgnored var debugImageWarned: String?
    /// The last port forwarding check of each running profile, from
    /// `ColimaModel+NetworkHealth`. It changes only when the report changes.
    private(set) var portHealth: [String: PortHealth.Report] = [:]
    /// The last DNS check of each running profile.
    private(set) var dnsHealth: [String: DNSHealth.Report] = [:]
    /// The profiles with a network check that runs now.
    private(set) var networkChecking: Set<String> = []
    /// Why the last ports check could not run, by check key. The notice shows it.
    private(set) var networkCheckErrors: [String: String] = [:]
    /// A diagnostics file is being collected and saved. One at a time.
    private(set) var isSavingDiagnostics = false
    /// The volume backup or restore that runs now, or nil. One at a time.
    private(set) var volumeTransfer: VolumeTransfer?
    /// The VM type change that runs now, or nil. One at a time.
    private(set) var recreate: VMRecreateProgress?
    /// The VM type changes that did not finish, by profile. The notice of the
    /// System tab shows the one of the selected profile.
    private(set) var pendingRecreate: [String: VMRecreateJournal] = [:]
    /// For tests: gets the notifications instead of `Notifier`.
    @ObservationIgnored var notifySink: ((String) -> Void)?
    /// The folder of the journals of a VM type change (`Paths.cacheDir`).
    @ObservationIgnored let recreateCacheDir: String
    /// A Doctor run was asked for while another one ran (a profile switch).
    /// The running one starts once more when it ends.
    @ObservationIgnored var isDoctorRunQueued = false
    /// The last start of the selected profile failed. It clears when the VM
    /// runs, and when another profile is selected. The stopped screen reads it.
    private(set) var startFailed = false
    /// The dashboard's selected tab, set by DashboardView. No view reads it
    /// here; it tells the model which costly data is on screen.
    @ObservationIgnored var dashboardTab: DashboardTab = .containers {
        didSet {
            guard dashboardTab != oldValue, visibleCount > 0 else { return }
            // An event changed disk use while no tab showed it: the rows are stale.
            if Self.showsDiskUsage(dashboardTab) { requestDF(urgent: diskDirty) }
            if dashboardTab == .system { Task { await refreshRouting() } }
        }
    }
    private(set) var alerts: [AlertItem] = []  // newest first, also shown in the dashboard
    var notificationsAllowed = true
    /// The wall clock time when the idle time started, or nil if the
    /// selected profile is not idle. The System tab shows it.
    private(set) var idleSince: Date?
    /// The wall clock time when auto-stop stops the selected profile, or nil.
    /// It moves later by the time that the Mac sleeps.
    private(set) var autoStopAt: Date?

    var profile = Defaults.string(.profile) ?? "default" {
        didSet {
            guard profile != oldValue else { return }
            Defaults.set(profile, .profile)
            switchProfile(from: oldValue)
        }
    }
    var notifyOnCrash = Defaults.bool(.notifyOnCrash) ?? true {
        didSet {
            guard notifyOnCrash != oldValue else { return }
            Defaults.set(notifyOnCrash, .notifyOnCrash)
            syncKeeper()
        }
    }
    /// Send "Healthy again" after an unhealthy alert. It works only while
    /// crash alerts are on.
    var notifyOnRecovery = Defaults.bool(.notifyOnRecovery) ?? false {
        didSet {
            guard notifyOnRecovery != oldValue else { return }
            Defaults.set(notifyOnRecovery, .notifyOnRecovery)
        }
    }
    /// The Compose projects whose banners are off (`MutedProjects`). It is
    /// per Mac, so it is not in the settings file.
    var mutedProjects = MutedProjects.decode(Defaults.strings(.mutedProjects)) {
        didSet {
            guard mutedProjects != oldValue else { return }
            Defaults.set(MutedProjects.encode(mutedProjects), .mutedProjects)
        }
    }
    /// Keep the logs of removed containers that fail. It works only while
    /// crash alerts are on, because the alert opens the saved lines.
    var keepRemovedLogs = Defaults.bool(.keepRemovedLogs) ?? false {
        didSet {
            guard keepRemovedLogs != oldValue else { return }
            Defaults.set(keepRemovedLogs, .keepRemovedLogs)
            syncKeeper()
        }
    }
    /// Open containers at .localhost names (`ColimaModel+Domains`). Off by default.
    var domainsEnabled = false {
        didSet {
            guard domainsEnabled != oldValue else { return }
            // A debug run never writes a setting.
            if !isDebug { domainsStore.set(domainsEnabled, forKey: Defaults.Key.domains.rawValue) }
            domainsSettingChanged()
        }
    }
    /// HTTPS for container domains (`ColimaModel+DomainsHTTPS`). Off by default.
    /// It changes only through `setHTTPS`.
    private(set) var httpsEnabled = false
    /// The custom suffix with a resolver file of ColimaBar (`ColimaModel+DomainSuffix`), or nil.
    private(set) var domainSuffix: String?
    private(set) var domainRoutes = DomainRoutes.empty
    private(set) var domainStatus = DomainStatus()
    /// The containers whose port the proxy held when they started. They need a restart.
    private(set) var domainRestartHints: [DomainRestartHint] = []
    /// The removed containers whose last lines `keeper` holds. The alerts
    /// strip reads it. It changes only when a buffer is kept or dropped.
    private(set) var savedLogIDs: Set<String> = []
    var autoStart = Defaults.bool(.autoStart) ?? true {
        didSet {
            guard autoStart != oldValue else { return }
            Defaults.set(autoStart, .autoStart)
            // A debug run must not change the proxy sockets.
            guard !isDebug else { return }
            autoStart ? proxy.start() : proxy.stop()
            profileProxies.setListening(autoStart)
            if autoStart { checkDockerContext() }
        }
    }
    /// Ask before a `colimabar://` link starts, stops or restarts a VM. Not in
    /// the settings file (`SettingsTransfer`).
    var askBeforeLinks = Defaults.bool(.askBeforeLinks) ?? true {
        didSet {
            guard askBeforeLinks != oldValue else { return }
            Defaults.set(askBeforeLinks, .askBeforeLinks)
        }
    }
    var autoStop = Defaults.bool(.autoStop) ?? false {
        didSet {
            Defaults.set(autoStop, .autoStop)
            resetIdle()
        }
    }
    var autoStopMinutes = Defaults.int(.autoStopMinutes).map(IdleMinutes.clamp) ?? 30 {
        didSet {
            let v = IdleMinutes.clamp(autoStopMinutes)
            if v != autoStopMinutes {
                autoStopMinutes = v
                return
            }
            Defaults.set(autoStopMinutes, .autoStopMinutes)
            resetIdle()
        }
    }
    /// Stop sooner on battery or in Low Power Mode (`AutoStopRule.limit`).
    var autoStopSooner = Defaults.bool(.autoStopSooner) ?? true {
        didSet {
            Defaults.set(autoStopSooner, .autoStopSooner)
            resetIdle()
        }
    }
    /// The power state. A debug run does not observe it, so it stays the default.
    private(set) var power = PowerState()
    /// The idle time that applies now.
    var autoStopLimit: AutoStopRule.Limit {
        AutoStopRule.limit(minutes: autoStopMinutes, power: power, stopSooner: autoStopSooner)
    }
    var hideIconWhenStopped = Defaults.bool(.hideIconWhenStopped) ?? false {
        didSet { Defaults.set(hideIconWhenStopped, .hideIconWhenStopped) }
    }
    /// Set when the app is reopened from Spotlight/Finder while its icon is
    /// hidden. It keeps the icon visible until the dashboard opens. When the
    /// last dashboard surface closes, or the VM starts, it clears, so the icon
    /// hides again if Colima is still stopped.
    var revealIcon = false

    /// Only the menu bar icon hides; the process, the auto-start proxy and the
    /// light heartbeat keep running so `docker` still wakes the VM.
    var iconHidden: Bool {
        Self.hidesIcon(
            enabled: hideIconWhenStopped, revealed: revealIcon, state: state,
            busy: busy != nil, dashboardOpen: visibleCount > 0,
            otherProfileRunning: profiles.contains { $0.isRunning && $0.name != profile })
    }

    /// The first time the icon ever hides, say where it went and how to get it
    /// back. Only once per user, not once per hide or per launch.
    func noteIconHiddenOnce() {
        // Another instance (during a launch handover) may have just set the
        // flag: re-read it from disk, and claim it atomically with a file.
        CFPreferencesAppSynchronize(kCFPreferencesCurrentApplication)
        guard !(Defaults.bool(.toldIconHidden) ?? false) else { return }
        let marker = "\(Paths.cacheDir)/told-icon-hidden"
        let fd = Darwin.open(marker, O_CREAT | O_EXCL | O_WRONLY, 0o600)
        Defaults.set(true, .toldIconHidden)
        guard fd >= 0 else { return }  // someone else claimed it first
        close(fd)
        Notifier.shared.post(
            "The icon is hidden while Colima is stopped. It comes back when Colima starts. To show it now, press the dashboard shortcut or open ColimaBar from Spotlight.",
            record: false)
    }

    /// Number of dashboard surfaces (popover, window) currently on screen.
    /// Live stats only stream while this is > 0.
    var visibleCount = 0 {
        didSet {
            guard (oldValue > 0) != (visibleCount > 0) else { return }
            if visibleCount == 0 { revealIcon = false }
            visibleCount > 0 ? becameVisible() : syncStatStreams()
            wakeHeartbeat()
        }
    }

    // Views and the menu bar icon read these many times per render. They are
    // stored, and recomputed only when `containers` changes.
    private(set) var running: [Container] = []
    private(set) var stopped: [Container] = []
    private(set) var unhealthyCount = 0
    var kubeContext: String { Paths.kubeContext(profile) }
    var isRosettaEnabled: Bool { config?.rosetta ?? false }
    var isKubernetesEnabled: Bool { config?.kubernetes ?? false }

    private(set) var api: DockerAPI
    let proxy: SocketProxy
    /// One proxy for each docker profile (see ProfileProxies).
    let profileProxies: ProfileProxies
    let log = Logger(category: "model")
    // Internal bookkeeping that no view reads: writes skip observation.
    /// Closes the dashboard popover, so a dialog is not hidden behind it.
    /// AppDelegate sets it.
    @ObservationIgnored var dismissPopover: @MainActor () -> Void = {}
    /// Shows the dashboard again, key and focused, after a dialog that
    /// `dismissPopover` made room for. AppDelegate sets it.
    @ObservationIgnored var restoreDashboard: @MainActor () -> Void = {}
    /// The colima-ctl.sh actions that run now, for each profile. A running
    /// action (for example a prune that waits for its dialog) is not idle.
    @ObservationIgnored private var actionsInFlight: [String: Int] = [:]
    /// The policy for container alerts. The glue in ColimaModel+ContainerAlerts
    /// uses it. The state is per event stream, so a profile switch resets it.
    @ObservationIgnored var alertGate = ContainerAlertGate()
    /// The ids with an unhealthy check that waits for the end of a start grace.
    /// The value is the token of the waiting task: a `destroy` removes the id,
    /// and a later event can add it again for a new task.
    @ObservationIgnored var deferredUnhealthy: [String: UUID] = [:]
    @ObservationIgnored private var events: StreamHandle?
    @ObservationIgnored private var statStreams: [String: StreamHandle] = [:]
    @ObservationIgnored private var latest: [String: Stat] = [:]  // written by stat streams, published once a second
    @ObservationIgnored private var tickTask: Task<Void, Never>?
    @ObservationIgnored private var tickSleep: Task<Void, Never>?  // the heartbeat's current sleep
    @ObservationIgnored private var containerRefresh: Task<Void, Never>?
    @ObservationIgnored private var reloadPending = false  // an event since the last refresh changed containers
    @ObservationIgnored private var dfGate = DFGate()
    /// The Cleanup page is on screen. It makes `wantsDF` true like a disk tab.
    @ObservationIgnored var cleanupOnScreen = false {
        didSet { if cleanupOnScreen, !oldValue { requestDF() } }
    }
    /// When the last log check ended, so the page does not ask again within 60 s.
    @ObservationIgnored var logSizesCheckedAt: Date?
    /// The time before which no weekly cleanup of a profile starts again, in
    /// this launch (see `PruneSchedule.retryAt`).
    @ObservationIgnored var pruneRetryAt: [String: Date] = [:]
    /// The probe of the log sizes. A test replaces it.
    @ObservationIgnored var logProbe: @Sendable (String) async -> CleanupProbe.LogCheck = {
        await CleanupProbe.logSizes(profile: $0)
    }
    /// The registry answers of all profiles (`Defaults.Key.imageUpdateCache`).
    @ObservationIgnored var imageUpdateCache = ImageUpdateCache()
    /// What the daemon said about the images of the containers at the last scan.
    @ObservationIgnored var imageScan = ImageUpdateRunner.Scan()
    @ObservationIgnored var imageScanning = false
    @ObservationIgnored var imageScanAgain = false
    /// A registry check runs now.
    @ObservationIgnored var imageChecking = false
    /// When the last registry check of each profile started, in this launch.
    @ObservationIgnored var imageRunAt: [String: Date] = [:]
    @ObservationIgnored var imageCheckNowAt: Date?
    /// The full references with a pull in progress, by profile. A pull blocks auto-stop.
    @ObservationIgnored var imagePulls: [String: Set<String>] = [:]
    /// A debug run loaded COLIMABAR_CLEANUP_FIXTURE: no df or log call replaces it.
    @ObservationIgnored var cleanupFixtureLoaded = false
    @ObservationIgnored private var dfToken = 0  // bumps when dfGate resets; older df tasks then stop
    @ObservationIgnored private var diskDirty = false  // an event changed images, volumes or disk use
    @ObservationIgnored private var lastColima = Date.distantPast
    @ObservationIgnored private var lastPing = Date()
    @ObservationIgnored private var dirWatcher: ColimaDirWatcher?
    @ObservationIgnored private(set) var isDebug = false
    /// The proxy of container domains. It listens only while the setting is on.
    @ObservationIgnored let domainProxy: any DomainProxying
    /// Where the setting is saved. A test process gets its own empty store, so no test reads or writes the real one.
    @ObservationIgnored let domainsStore: UserDefaults
    @ObservationIgnored var domainCandidates: [DomainCandidate] = []
    /// The host ports of every running container, internal ones too.
    @ObservationIgnored var domainPublished: Set<Int> = []
    /// The ports of all known containers of this profile, stopped ones too.
    @ObservationIgnored var domainClaims = DomainPortClaims()
    @ObservationIgnored var domainStartToken = 0
    @ObservationIgnored var domainRebindAt: Date?
    /// The published ports at the last start. A change gives a failed proxy a new try.
    @ObservationIgnored var domainStartPublished: Set<Int> = []
    @ObservationIgnored var domainRecheck: Task<Void, Never>?
    /// The wait before the next try of a failed proxy.
    @ObservationIgnored var domainRetry: Task<Void, Never>?
    /// The tries since the proxy failed. It sets the wait (`DomainTimings.failureDelay`).
    @ObservationIgnored var domainRetryCount = 0
    /// The last time that a tick moved the proxy back to port 80, or tried it.
    @ObservationIgnored var domainMoveBackAt = Date.distantPast
    @ObservationIgnored var domainMoveBackProbing = false
    @ObservationIgnored var domainTimings = DomainTimings()
    /// COLIMABAR_DOMAINS=1 in a debug run: show the names, start nothing.
    @ObservationIgnored var domainsShownInDebug = false
    /// The disk, keychain and TLS work of HTTPS. A test gives it a fake.
    @ObservationIgnored let domainTLS: any DomainTLSServicing
    /// The DNS server of the custom suffix. A test gives it a fake.
    @ObservationIgnored var dnsResponder: any DNSServing
    /// Runs `osascript` for the resolver file. A test gives it a fake, and the system runner refuses in a test process.
    @ObservationIgnored var resolverRun: ResolverInstaller.Runner = ResolverInstaller.systemRun
    /// The folder of the resolver files. A test process points it at a folder that does not exist.
    @ObservationIgnored var resolverDir = ResolverFile.dir
    /// Looks up a name through the system resolver and reports whether it gives 127.0.0.1.
    @ObservationIgnored var resolverCheck: @Sendable (String) async -> Bool = {
        await LoopbackLookup.resolvesToLoopback($0)
    }
    /// True when nothing holds this UDP port.
    @ObservationIgnored var dnsPortFree: @Sendable (Int) -> Bool = { DNSResponder.isFree(port: $0) }
    @ObservationIgnored var dnsStartToken = 0
    @ObservationIgnored var dnsRetry: Task<Void, Never>?
    /// The delayed checks of the system resolver while the phase is `.notUsedYet`.
    @ObservationIgnored var dnsRecheck: Task<Void, Never>?
    @ObservationIgnored var tlsCA: LocalCA?
    /// True after the self-test of the TLS identities passed.
    @ObservationIgnored var tlsIdentitiesWork = false
    @ObservationIgnored var leafCache: LeafCache?
    @ObservationIgnored var tlsMode: DomainTLSServer.Mode = .perSNI
    /// The routes at the last start of the HTTPS listener.
    @ObservationIgnored var httpsStartPublished: Set<Int> = []
    /// Each start, stop and failure of HTTPS makes the older ones stale.
    @ObservationIgnored var httpsStartToken = 0
    @ObservationIgnored var httpsSetupTask: Task<Void, Never>?
    @ObservationIgnored var multiSANTask: Task<Void, Never>?
    @ObservationIgnored var multiSANRenewTask: Task<Void, Never>?
    @ObservationIgnored var httpsTrustCheckedAt = Date.distantPast
    @ObservationIgnored var httpsTrustChecking = false
    @ObservationIgnored var httpsRetry: Task<Void, Never>?
    @ObservationIgnored var httpsRetryCount = 0
    @ObservationIgnored var httpsRebindAt: Date?
    @ObservationIgnored var httpsRecheck: Task<Void, Never>?
    @ObservationIgnored var httpsMoveBackAt = Date.distantPast
    @ObservationIgnored var httpsMoveBackProbing = false
    @ObservationIgnored var httpsIdentityTask: Task<Bool, Never>?
    /// The names of the certificate that the fallback mode serves.
    @ObservationIgnored var multiSANServed: [String] = []
    /// The generation of the certificate of the fallback mode. Each listener of that mode makes the next one.
    @ObservationIgnored var multiSANEpoch = 0
    /// The queue of the certificate minting, apart from the queue of the proxy.
    @ObservationIgnored let tlsMintQueue = DispatchQueue(label: "colimabar.domains.mint")
    /// The runner of the volume transfer that runs now.
    @ObservationIgnored var volumeRunner: VolumeBackupRunner?
    /// The runner of the image save or load of a VM type change.
    @ObservationIgnored var imageRunner: ImageArchiveRunner?
    /// The profile of that transfer, and why it stopped if the VM or the profile changed.
    @ObservationIgnored var volumeProfile: String?
    @ObservationIgnored var volumeStop: VolumeTransferStop?
    /// The profiles whose leftover helper containers were removed in this launch.
    @ObservationIgnored var helperSwept: Set<String> = []
    /// The upgrade guard seeded its record of good starts in this launch.
    @ObservationIgnored var upgradeSeedTried = false
    @ObservationIgnored var upgradeSeedRunning = false
    /// The tools whose failed version probe the log has shown in this launch.
    @ObservationIgnored var upgradeProbeLogged: Set<String> = []
    @ObservationIgnored var goodStartsProblemLogged = false
    @ObservationIgnored private var isCheckingContext = false
    @ObservationIgnored private var contextCheckAgain = false
    /// The modification time of the docker config file at the last tick.
    @ObservationIgnored private var configStamp: Date?
    /// When a failed docker context check can run again.
    @ObservationIgnored private var contextRetryAt: Date?
    @ObservationIgnored private var contextFailures = 0
    @ObservationIgnored private(set) var generation = 0  // bumps on profile switch; stale callbacks are ignored
    // Drops `colima list` results older than the last applied one.
    @ObservationIgnored private var statusOrder = LatestOnly()
    @ObservationIgnored private var isConfirmingAutoStop = false  // an auto-stop check runs a fresh list
    @ObservationIgnored private var localBusy: String?  // VM action launched here, marker not written yet
    // One wake at a time for each profile. The stable socket and the profile
    // socket can both ask to start the same profile.
    @ObservationIgnored private var wakes: [String: (token: Int, task: Task<Bool, Never>)] = [:]
    @ObservationIgnored private var wakeToken = 0
    // Auto-stop state of the running profiles other than the selected one.
    @ObservationIgnored private var otherIdle: [String: OtherIdle] = [:]
    /// The auto-stop times in the last status file that the app wrote, and
    /// whether the last write failed (see ColimaModel+AppStatus).
    @ObservationIgnored var appStatusTimes: [String: Date]?
    @ObservationIgnored var appStatusWriteFailed = false
    // When the idle time of the selected profile started. `SuspendingClock`
    // stops while the Mac sleeps, as the VM does.
    @ObservationIgnored private var idleStart: SuspendingClock.Instant?
    // The observer of system sleep (not created in a debug run) and the
    // check that runs after a system sleep. The newest check wins.
    @ObservationIgnored private var powerObserver: SystemPowerObserver?
    @ObservationIgnored private var afterSleep: Task<Void, Never>?
    // One notification for each profile and kind every 30 minutes, whatever
    // the number of system sleeps.
    @ObservationIgnored private var afterSleepAlerts = AlertThrottle(window: 30 * 60)
    // The profiles with a clock fix that runs now. A new check must not fix again.
    @ObservationIgnored private var clockFixes: Set<String> = []
    // The network checks (see ColimaModel+NetworkHealth): the observer (not
    // created in a debug run), the wait before a check after a network
    // change, the time of the last check of each profile, the checks that
    // run now, and the notifications that were sent. One notification for
    // each profile and kind every 60 minutes.
    @ObservationIgnored var networkObserver: NetworkObserver?
    @ObservationIgnored var networkDebounce: Task<Void, Never>?
    @ObservationIgnored var networkChecked: [String: Date] = [:]
    @ObservationIgnored var networkRunning: Set<String> = []
    @ObservationIgnored var networkAlerts = AlertThrottle(window: 60 * 60)
    // The start of a sleep, until the after-wake path ran. A network change
    // is ignored while it is set and not too old (`networkPauseActive`).
    @ObservationIgnored var networkPausedAt: Date?
    // The colimabar-PROFILE contexts: the last applied and the next wanted set.
    @ObservationIgnored private var appliedContexts: [String: String]?
    @ObservationIgnored private var wantedContexts: [String: String]?
    @ObservationIgnored private var isApplyingContexts = false
    // The last set that ProfileContexts.apply failed for, and when.
    @ObservationIgnored private var contextsFailure: (wanted: [String: String], at: Date)?
    // Not observed: its buffers change with each log line.
    @ObservationIgnored private let keeper: RemovedLogKeeper
    private let historyLen = 60

    /// The dashboard keeps at most this many alerts.
    static let alertCap = 20
    /// How long a proxy wake waits for another start or stop to finish.
    static let startWaitSeconds = 300
    /// Exit codes of a normal stop: no crash alert for them. 130 is SIGINT,
    /// 137 SIGKILL and 143 SIGTERM.
    nonisolated static let ignoredExitCodes: Set<String> = ["0", "130", "137", "143"]

    /// `profile` and `readOnly` are for the `colimabar` command. The command
    /// shows a profile that the user names, and it must change nothing: a
    /// read-only model counts as a debug run, so it never starts a proxy,
    /// changes a route or a context, or writes a setting. The command never
    /// calls `start()`. Assigning `profile` here runs no `didSet`.
    /// `dockerAPI` is for tests: a fake daemon instead of the socket of the profile.
    /// `recreateCacheDir` is for tests: the folder of the VM type change journals.
    /// A test process gets an empty temporary folder if it passes none.
    /// `domainProxy`, `domainsEnabled` and `domainsStore` are for tests too: a
    /// fake proxy, a start value of the setting, and a store for it. A test
    /// process that passes none gets an inert proxy and an empty store, so a
    /// model never binds a port or touches the saved setting by accident.
    init(
        profile named: String? = nil, readOnly: Bool = false, dockerAPI: DockerAPI? = nil,
        domainProxy: (any DomainProxying)? = nil, domainsEnabled: Bool? = nil, domainsStore: UserDefaults? = nil,
        httpsEnabled: Bool? = nil, domainTLS: (any DomainTLSServicing)? = nil, domainSuffix: String? = nil,
        recreateCacheDir: String? = nil
    ) {
        self.recreateCacheDir =
            recreateCacheDir ?? (TestProcess.isRunning ? TestProcess.emptyCacheDir() : Paths.cacheDir)
        let inTest = TestProcess.isRunning
        self.domainProxy = domainProxy ?? (inTest ? InertDomainProxy() : DomainProxy())
        self.domainTLS = domainTLS ?? (inTest ? InertDomainTLS() : SystemDomainTLS())
        dnsResponder = inTest ? InertDNSResponder() : DNSResponder()
        if inTest {
            resolverDir = NSTemporaryDirectory() + "colimabar-no-resolver-\(getpid())"
            resolverCheck = { _ in false }
            dnsPortFree = { _ in false }
        }
        let store = domainsStore ?? (inTest ? TestProcess.emptyStore() : .standard)
        self.domainsStore = store
        self.domainsEnabled =
            domainsEnabled ?? (store.object(forKey: Defaults.Key.domains.rawValue) as? Bool) ?? false
        self.httpsEnabled =
            httpsEnabled ?? (store.object(forKey: Defaults.Key.domainsHTTPS.rawValue) as? Bool) ?? false
        self.domainSuffix = (domainSuffix ?? store.string(forKey: Defaults.Key.domainSuffix.rawValue))
            .flatMap(DomainSuffix.valid)
        imageUpdateCheck = (store.object(forKey: Defaults.Key.imageUpdateCheck.rawValue) as? Bool) ?? false
        imageUpdateCache = ImageUpdateCache.decode(store.string(forKey: Defaults.Key.imageUpdateCache.rawValue))
        let p = named ?? Defaults.string(.profile) ?? "default"
        profile = p
        isDebug = readOnly
        let client = dockerAPI ?? DockerAPI(socketPath: Paths.socket(p))
        api = client
        keeper = RemovedLogKeeper(api: client)
        proxy = SocketProxy(upstream: Paths.socket(p))
        proxy.apiVersion = Defaults.string(.apiVersion)
        profileProxies = ProfileProxies()
        profileProxies.apiVersion = proxy.apiVersion
        keeper.onChange = { [weak self] ids in self?.set(\.savedLogIDs, ids) }
        syncKeeper()
    }

    /// The keeper opens streams only while both settings are on.
    private func syncKeeper() {
        keeper.isEnabled = keepRemovedLogs && notifyOnCrash
    }

    func start(debug: Bool = false) {
        isDebug = debug
        if !debug {
            proxy.wake = { [weak self] in await self?.wakeForProxy() ?? false }
            if autoStart { proxy.start() } else { proxy.stop() }
            // The proxies appear with the first `colima list` (syncProfiles).
            profileProxies.wake = { [weak self] p in await self?.wakeForProxy(profile: p) ?? false }
            profileProxies.setListening(autoStart)
            configStamp = Routing.configStamp()
            Task {
                await Routing.apply(selected: profile)
                routing = await Routing.status()
            }
            dirWatcher = makeDirWatcher()
            // A debug run changes nothing, so it does not observe system sleep.
            let observer = SystemPowerObserver()
            observer.onSleep = { [weak self] in self?.systemSleepBegan() }
            observer.onSleepEnd = { [weak self] in self?.systemSleepEnded() }
            observer.onPowerChange = { [weak self] in self?.powerChanged($0) }
            set(\.power, observer.power)
            let p = observer.power
            log.notice(
                "power at start: battery \(p.onBattery, privacy: .public), low power \(p.lowPowerMode, privacy: .public), hot \(p.isHot, privacy: .public)"
            )
            powerObserver = observer
            startNetworkObserver()
            publishAppStatus()
            // Older versions left temporary keychain files in the cache folder.
            domainTLS.cleanStale()
            if domainsEnabled { startDomainProxy(retryFirst: true) }
            startHTTPSAtLaunch()
            if domainsEnabled, domainSuffix != nil { Task { await startDNSResponder() } }
        } else {
            setDomainStatus(DomainStatus(phase: .debugRun))
        }
        Task { await refreshAll() }
        lastPing = Date()
        tickTask = Task {
            while !Task.isCancelled {
                let interval = Self.tickInterval(
                    state: state, busy: busy != nil, dashboardOpen: visibleCount > 0, saving: heartbeatSaving)
                // A separate task, so wakeHeartbeat() can end the sleep early.
                let sleep = Task { _ = try? await Task.sleep(for: interval, tolerance: interval / 2) }
                tickSleep = sleep
                await sleep.value
                await tick()
            }
        }
    }

    /// Any profile starting, stopping, appearing or going away changes the
    /// watched folders, so no frequent `colima list` is needed.
    private func makeDirWatcher() -> ColimaDirWatcher {
        ColimaDirWatcher(root: Paths.colimaDir, lima: Paths.limaDir) { [weak self] in
            Task { await self?.refreshStatus() }
        }
    }

    /// The heartbeat saves nothing while a dashboard is open or an action runs.
    private var heartbeatSaving: PowerState.Saving {
        visibleCount > 0 || busy != nil ? .off : power.saving
    }

    /// The power state changed. The idle time does not restart: the stop time
    /// follows the new limit at the next check.
    private func powerChanged(_ new: PowerState) {
        guard new != power else { return }
        power = new
        log.notice(
            "power changed: battery \(new.onBattery, privacy: .public), low power \(new.lowPowerMode, privacy: .public), hot \(new.isHot, privacy: .public)"
        )
        // The stop time and its note follow at once, not at the next tick.
        checkIdle()
        wakeHeartbeat()
    }

    /// Ends the heartbeat's current sleep, so a tick runs now and the next
    /// sleep uses the interval for the new state.
    private func wakeHeartbeat() {
        tickSleep?.cancel()
    }

    /// Writes only the lists that changed, so views that read the others
    /// don't redraw.
    private func updateDerivedLists() {
        let d = Self.derivedLists(containers)
        if d.running != running { running = d.running }
        if d.stopped != stopped { stopped = d.stopped }
        if d.unhealthy != unhealthyCount { unhealthyCount = d.unhealthy }
    }

    /// What runs now that an in-app update must not interrupt (see
    /// UpdatePolicy.blocker): the busy marker or action of any profile, the
    /// colima-ctl.sh actions, the wakes, the open docker transfers, a Doctor
    /// run (a fix or a repair too) and a diagnostics save.
    var updateActivity: UpdatePolicy.Activity {
        var names = Set(profiles.map(\.name))
        names.insert(profile)
        names.formUnion(profileActions.keys)
        names.formUnion(actionsInFlight.keys)
        var labels: [String] = []
        for p in names.sorted() {
            if let label = Self.updateBusyLabel(marker: readBusy(p), actionsInFlight: busyActions(p)) {
                labels.append(label)
            }
        }
        let transfers = proxy.activeTransfers() + names.reduce(0) { $0 + profileProxies.activeTransfers($1) }
        return UpdatePolicy.Activity(
            busyLabels: labels, transfers: transfers, wakes: wakes.count, doctorRunning: isDoctorRunning,
            savingDiagnostics: isSavingDiagnostics)
    }

    /// True from the swap of an in-app update until this copy quits or the
    /// restart fails. No new VM action or proxy wake starts then.
    var updateRestarting: Bool { Updater.shared.phase == .installing }

    /// Called on quit: the stable socket becomes a symlink to Colima's, so
    /// docker clients keep working without ColimaBar.
    func shutdown() {
        proxy.stop()
        if !isDebug {
            invalidateDomainTasks()
            stopHTTPSForQuit()
            invalidateDNSTasks()
            dnsResponder.stop()
            domainProxy.stop()
            profileProxies.shutdown()
            AppStatusFile.removeIfOwned()
        }
    }

    /// Heartbeat (see tickInterval). Cheap work only: a stat() of the busy
    /// marker, publishing the stat streams' latest numbers, and a socket
    /// /_ping every 3 s (dashboard open) or 10 s (closed).
    private func tick() async {
        // A new Colima folder (for example ~/.colima made by a colima call
        // in a terminal) moves every socket: refresh at once.
        if Paths.colimaFoldersMoved { await refreshStatus() }
        let stamp = Routing.configStamp()
        if Self.contextCheckDue(stamp: stamp, lastStamp: configStamp, retryAt: contextRetryAt, now: Date()) {
            if stamp != configStamp { contextFailures = 0 }
            configStamp = stamp
            contextRetryAt = nil
            checkDockerContext()
        }
        domainsHeartbeat()
        let b = readBusy()
        if b != busy {
            let finished = busy != nil && b == nil
            busy = b
            if finished { await refreshAll() }
        }
        if visibleCount > 0 { publishStats() }

        let saving = heartbeatSaving
        let staleAfter = Self.staleAfter(state: state, saving: saving)
        // A containerd profile has no docker socket, so a ping says nothing
        // about it. Refresh its state only when it is stale.
        if !hasDockerSocket {
            if Date().timeIntervalSince(lastColima) > staleAfter { await refreshStatus() }
        } else if Date().timeIntervalSince(lastPing) >= Self.pingInterval(
            dashboardOpen: visibleCount > 0, saving: saving) - 0.5
        {
            // The 0.5 s margin absorbs the sleep's tolerance.
            lastPing = Date()
            let ping = await api.get("/_ping", timeout: 2)
            let up = ping?.ok ?? false
            if let v = ping?.headers["api-version"], v != proxy.apiVersion {
                proxy.apiVersion = v
                profileProxies.apiVersion = v
                profileProxies.setAPIVersion(v, for: profile)
                Defaults.set(v, .apiVersion)
            }
            let stale = Date().timeIntervalSince(lastColima) > staleAfter
            if up != (state == .running) || stale {
                await refreshStatus()
            } else if up, events == nil {
                startEvents()
            }
        }
        checkIdle()
        checkOtherProfilesIdle()
        checkScheduledPrune()
        checkImageUpdates()
        publishAppStatus()
    }

    /// False when the profile's runtime is known and isn't docker (e.g.
    /// containerd): then no docker socket answers, so ColimaBar doesn't ping
    /// it, stream its events or list its containers.
    var hasDockerSocket: Bool { Self.hasDockerSocket(runtime: vm.runtime) }

    /// True while an action of the selected profile runs.
    var hasActionInFlight: Bool { busyActions(profile) > 0 }

    /// The actions and the pulls of ColimaBar that run for a profile. Each
    /// one blocks auto-stop, the weekly cleanup and the check of images.
    func busyActions(_ p: String) -> Int { (actionsInFlight[p] ?? 0) + (imagePulls[p]?.count ?? 0) }

    /// The selected profile's busy marker, or the label of an action this app
    /// just launched whose script hasn't written its marker yet.
    private func readBusy() -> String? {
        Self.readBusyMarker(profile) ?? localBusy
    }

    /// The busy marker of any profile, or an action this app runs for it.
    func busyMarker(of p: String) -> String? { readBusy(p) }

    private func readBusy(_ p: String) -> String? {
        p == profile ? readBusy() : Self.readBusyMarker(p) ?? profileActions[p]
    }

    /// The label in the busy marker colima-ctl.sh writes while a VM action
    /// runs. A marker whose script is gone is removed (see `BusyMarker`).
    nonisolated private static func readBusyMarker(_ profile: String) -> String? {
        let path = Paths.busy(profile)
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
            let mtime = attrs[.modificationDate] as? Date
        else { return nil }
        let marker = BusyMarker.parse((try? String(contentsOfFile: path, encoding: .utf8)) ?? "")
        if BusyMarker.isStale(
            mtime: mtime, now: Date(), pid: marker.pid,
            ownerStarted: marker.pid.flatMap { ProcessProbe.startTime(pid: $0) })
        {
            try? FileManager.default.removeItem(atPath: path)
            return nil
        }
        return marker.label
    }

    // MARK: - Refresh

    /// `urgentDF`: a user action changed disk use, so df skips the 30 s gap.
    func refreshAll(urgentDF: Bool = false) async {
        await refreshStatus()
        if state == .running {
            await refreshContainers()
            requestDF(urgent: urgentDF)
        }
    }

    /// Returns false when `colima list` did not give a list: colima is missing,
    /// the call failed or timed out, or the profile changed during the call.
    @discardableResult
    func refreshStatus() async -> Bool {
        lastColima = Date()
        if Paths.refreshColimaFolders() { colimaFoldersChanged() }
        // Profiles and Lima instances come and go: watch the current set.
        dirWatcher?.rearm()
        guard Shell.which("colima") != nil else {
            set(\.state, .notInstalled)
            return false
        }
        let gen = generation
        // The directory watcher and the heartbeat can both start a refresh.
        // An older `colima list` can end later; its result must not undo a
        // newer one (an old "Running" after a new "Stopped").
        let seq = statusOrder.begin()
        let r = await Shell.run(["colima", "list", "-j"], timeout: 10)
        guard gen == generation else { return false }
        // A slow or failed `colima list` says nothing about the VM: keep the
        // current state instead of treating it as "stopped".
        guard r.ok else {
            log.error("colima list failed (status \(r.status)); keeping state")
            return false
        }
        guard statusOrder.apply(seq) else { return true }
        let dec = JSONDecoder()
        let all = r.out.split(separator: "\n").compactMap { try? dec.decode(ColimaListJSON.self, from: Data($0.utf8)) }
        // The selected profile was deleted (`colima delete -p X`): fall back
        // to default, so auto-start never provisions a fresh VM under the old
        // name. profile's didSet switches over and refreshes again.
        // A disk shrink deletes the profile for a short time while its busy
        // marker exists: keep the profile then.
        // A debug run changes no setting, so it keeps the profile.
        if !isDebug, profile != "default", readBusy() == nil, !all.isEmpty,
            !all.contains(where: { ($0.name ?? "default") == profile })
        {
            log.notice("profile \(self.profile, privacy: .public) no longer exists; switching to default")
            profile = "default"
            return false
        }
        let wasRunningNames = Set(profiles.filter(\.isRunning).map(\.name))
        let hadProfiles = !profiles.isEmpty
        set(
            \.profiles,
            all.map {
                ProfileRow(
                    name: $0.name ?? "default", isRunning: $0.status == "Running", cpus: $0.cpus ?? 0,
                    memGB: ByteFormat.gib(bytes: $0.memory ?? 0), runtime: $0.runtime ?? "",
                    status: $0.status)
            })
        syncProfiles()
        loadRecreateJournals()
        pruneNetworkHealth()
        seedGoodStarts()
        // `colima start` switches the docker context, and `colima stop`
        // deletes it. Check it when a profile starts or stops.
        if hadProfiles, Set(profiles.filter(\.isRunning).map(\.name)) != wasRunningNames { checkDockerContext() }
        let info = all.first { ($0.name ?? "default") == profile }
        let newState: VMState = info?.status == "Running" ? .running : .stopped
        let wasRunning = state == .running

        // Read colima.yaml first: the address check below needs its newest value.
        reloadConfig()
        if newState != .running || !wasRunning { addressUnavailable = false }
        if let info {
            var v = vm
            v.arch = info.arch ?? ""
            v.runtime = info.runtime ?? ""
            v.cpus = info.cpus ?? 0
            v.memGB = ByteFormat.gib(bytes: info.memory ?? 0)
            v.diskGB = Int((info.disk ?? 0) / ByteFormat.bytesPerGiB)
            // The address of a VM that has `address: true` can come after the start.
            let wantsAddress = Self.needsAddressCheck(
                address: vmSettings?.address == true, ipAddress: v.ipAddress, unavailable: addressUnavailable)
            if newState == .running && (!wasRunning || v.driver.isEmpty || wantsAddress) {
                let s = await Shell.run(["colima", "status", "-j", "--profile", profile], timeout: 10)
                guard gen == generation, statusOrder.isLatestApplied(seq) else { return true }
                if let st = try? dec.decode(ColimaStatusJSON.self, from: Data(s.out.utf8)) {
                    v.driver = st.driver ?? ""
                    v.mountType = st.mount_type ?? ""
                    v.ipAddress = st.ip_address ?? ""
                }
                if wantsAddress, v.ipAddress.isEmpty {
                    addressUnavailable = true
                    log.notice("profile \(self.profile, privacy: .public): colima status gives no IP address")
                }
            }
            set(\.vm, v)
        }
        if state != newState {
            log.notice("profile \(self.profile, privacy: .public): \(String(describing: newState), privacy: .public)")
        }
        set(\.state, newState)

        if newState == .running {
            set(\.startFailed, false)
            if events == nil { startEvents() }
            if !wasRunning {
                revealIcon = false
                await refreshContainers()
                guard gen == generation else { return true }
                requestDF()
            }
        } else {
            clearVMData(because: .vmStopped)
        }
        return true
    }

    /// Reads the colima.yaml of the selected profile. A missing file gives
    /// nil, so no flags of an older file stay. `set` assigns only a change.
    func reloadConfig() {
        let data = try? Data(contentsOf: URL(fileURLWithPath: Paths.config(profile)))
        let text = data.flatMap { String(data: $0, encoding: .utf8) }
        set(\.config, text.map(VMConfig.parse))
        set(\.vmSettings, text.map(VMSettings.read))
        set(\.vmSettingsSHA, text == nil ? nil : data.map(Self.configSHA))
    }

    /// True if the refresh must ask `colima status` for the IP address of
    /// the VM: the file has `address: true`, the IP address is not known and
    /// no check of this start found none.
    nonisolated static func needsAddressCheck(address: Bool, ipAddress: String, unavailable: Bool) -> Bool {
        address && ipAddress.isEmpty && !unavailable
    }

    func clearVMData(because: VolumeTransferStop) {
        stopVolumeTransferForVMChange(because)
        imageRunner?.cancel()
        events?.cancel()
        events = nil
        resetDF()
        syncStatStreams()
        set(\.containers, [])
        // A stopped VM keeps the ports that its containers claim. A profile switch forgets them.
        if because == .profileChanged { domainClaims.reset() }
        setDomainRestartHints([])
        updateDomainRoutes([], authoritative: false)
        set(\.stats, [:])
        set(\.images, [])
        set(\.volumes, [])
        set(\.df, [])
        set(\.cleanup, .empty)
        set(\.logSizes, nil)
        set(\.logItems, .init())
        set(\.logSizesError, nil)
        set(\.logSizesChecking, false)
        logSizesCheckedAt = nil
        resetImageUpdates()
        set(\.cpuHistory, [])
        set(\.memHistory, [])
    }

    private func switchProfile(from old: String) {
        // An action that this app runs keeps its label on its own profile, so
        // the profile menu shows it until the action ends (see execute).
        if let b = localBusy { profileActions[old] = b }
        localBusy = profileActions.removeValue(forKey: profile)
        set(\.startFailed, false)
        addressUnavailable = false
        // At once, not on the next tick: the Delete guard of the menu reads it.
        set(\.busy, readBusy())
        retargetSocket()
        syncWakeHolds()
        Task { await refreshAll() }
    }

    /// Points the API client, the saved logs and the stable proxy at the
    /// socket of the selected profile, and forgets the data of the old socket.
    private func retargetSocket() {
        generation += 1
        alertGate = ContainerAlertGate()
        deferredUnhealthy = [:]
        clearVMData(because: .profileChanged)
        set(\.diskImage, nil)
        for h in statStreams.values { h.cancel() }
        statStreams = [:]
        latest = [:]
        api = DockerAPI(socketPath: Paths.socket(profile))
        keeper.reset(api: api)  // saved logs belong to the old socket
        // A stopped proxy links its path to the new upstream. A debug run
        // must not change the proxy sockets.
        if !isDebug { proxy.upstream = Paths.socket(profile) }
        vm = VMInfo()
        set(\.config, nil)
        state = .unknown
        resetIdle()
    }

    /// The Colima folder changed (see Paths.refreshColimaFolders). Every
    /// socket, colima.yaml and watched folder moves with it.
    private func colimaFoldersChanged() {
        log.notice("the Colima folder is now \(Paths.colimaDir, privacy: .public)")
        retargetSocket()
        guard !isDebug else { return }
        profileProxies.refreshUpstreams()
        if dirWatcher != nil { dirWatcher = makeDirWatcher() }
    }

    /// True if the list was refreshed from the daemon.
    @discardableResult
    func refreshContainers() async -> Bool {
        guard hasDockerSocket else { return false }
        let gen = generation
        guard let r = await api.get("/containers/json?all=1"), r.ok, gen == generation, state == .running,
            let list = try? JSONDecoder().decode([APIContainer].self, from: r.body)
        else { return false }
        // The helper containers of a volume backup are not the user's containers.
        let visible = Self.visibleContainers(list)
        let mapped = visible.map { c in
            Container(
                id: c.Id, name: c.Names.first.map { String($0.drop { $0 == "/" }) } ?? String(c.Id.prefix(12)),
                image: c.Image, state: c.State, status: c.Status,
                ports: Array(Set((c.Ports ?? []).compactMap { $0.IP != nil ? $0.PublicPort : nil })).sorted(),
                project: c.Labels?["com.docker.compose.project"],
                compose: c.Labels.flatMap { ComposeProject.from(labels: $0) }, imageID: c.ImageID ?? "")
        }
        // Stable order by name: rows never reorder because a number changed.
        set(\.containers, mapped.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending })
        updateDomainRoutes(visible)
        syncStatStreams()
        scheduleImageUpdateScan()
        await refreshComposeIssues()
        sweepHelperLeftoversOnce()
        return true
    }

    /// True while a dashboard shows a tab with `/system/df` data.
    private var wantsDF: Bool {
        Self.wantsDF(
            visible: visibleCount > 0, tab: dashboardTab, cleanupOnScreen: cleanupOnScreen, running: state == .running,
            hasDockerSocket: hasDockerSocket, fixtureLoaded: cleanupFixtureLoaded)
    }

    /// Asks for fresh `/system/df` data. dockerd walks every volume and
    /// container layer for it, which can take seconds. So it runs only while
    /// a tab shows the data, one at a time, and at most once per 30 s (see
    /// DFGate). Requests in between join into one run.
    ///
    /// `urgent`: a user action (remove, prune, pull) changed disk use. The
    /// run skips the 30 s gap, so the Images and Volumes rows update at once.
    /// It still waits for a run in flight.
    func requestDF(urgent: Bool = false) {
        guard wantsDF else { return }
        scheduleDF(dfGate.request(now: Date(), urgent: urgent))
    }

    private func scheduleDF(_ step: DFGate.Step) {
        guard case .run(let wait) = step else { return }
        let gen = generation
        let token = dfToken
        let ticket = dfGate.ticket
        Task {
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            guard gen == generation, token == dfToken else { return }
            // An urgent request replaced this waiting run.
            guard ticket == dfGate.ticket else { return }
            // The tab may have closed during the wait.
            guard wantsDF else {
                dfGate.skip()
                return
            }
            dfGate.begin()
            diskDirty = false
            await refreshDF()
            guard gen == generation, token == dfToken else { return }
            scheduleDF(dfGate.end(now: Date()))
        }
    }

    /// Forgets the df schedule, for example when the VM stops.
    private func resetDF() {
        dfToken += 1
        dfGate = DFGate()
        diskDirty = false
    }

    private func refreshDF() async {
        let gen = generation
        guard let r = await api.get("/system/df", timeout: 30), r.ok, gen == generation,
            let d = try? JSONDecoder().decode(APIDF.self, from: r.body)
        else { return }
        applyDF(d)
    }

    /// Publishes the disk use rows, the image and volume rows and the Cleanup
    /// rows of one `/system/df` answer. Internal, so a test and the debug
    /// fixture can call it.
    func applyDF(_ d: APIDF) {
        let imgs = d.Images ?? []
        let ctrs = d.Containers ?? []
        let vols = d.Volumes ?? []
        let cache = d.BuildCache ?? []
        let unusedImg = imgs.filter { $0.Containers == 0 }
        let unusedVol = vols.filter { ($0.UsageData?.RefCount ?? 0) == 0 }
        func sum<T>(_ xs: [T], _ f: (T) -> Int64) -> Double { Double(xs.reduce(0) { $0 + max(f($1), 0) }) }
        set(
            \.df,
            [
                DFRow(
                    type: "Images", count: imgs.count, size: sum(imgs) { $0.Size },
                    reclaimable: sum(unusedImg) { $0.Size - ($0.SharedSize ?? 0) }),
                DFRow(
                    type: "Containers", count: ctrs.count, size: sum(ctrs) { $0.SizeRw ?? 0 },
                    reclaimable: sum(ctrs.filter { $0.State != "running" }) { $0.SizeRw ?? 0 }),
                DFRow(
                    type: "Volumes", count: vols.count, size: sum(vols) { $0.UsageData?.Size ?? 0 },
                    reclaimable: sum(unusedVol) { $0.UsageData?.Size ?? 0 }),
                DFRow(
                    type: "Build cache", count: cache.count, size: sum(cache) { $0.Size },
                    reclaimable: sum(cache.filter { !$0.InUse && !$0.Shared }) { $0.Size }),
            ])
        set(
            \.images,
            imgs.flatMap { i -> [ImageRow] in
                let tags = (i.RepoTags ?? []).filter { $0 != "<none>:<none>" }
                let created = Date(timeIntervalSince1970: TimeInterval(i.Created))
                if tags.isEmpty {
                    return [
                        ImageRow(
                            id: i.Id, repo: "<none>", tag: "<none>", size: Double(i.Size),
                            created: created, containers: i.Containers)
                    ]
                }
                return tags.map { t in
                    let colon = t.lastIndex(of: ":") ?? t.endIndex
                    return ImageRow(
                        id: i.Id + t, repo: String(t[..<colon]),
                        tag: colon < t.endIndex ? String(t[t.index(after: colon)...]) : "",
                        size: Double(i.Size), created: created, containers: i.Containers)
                }
            }.sorted { $0.size > $1.size })
        set(
            \.volumes,
            vols.map {
                VolumeRow(
                    name: $0.Name, size: Double($0.UsageData?.Size ?? 0), links: $0.UsageData?.RefCount ?? 0,
                    project: $0.Labels?["com.docker.compose.project"],
                    isAnonymous: $0.Labels?["com.docker.volume.anonymous"] != nil)
            }.sorted { ($0.links, $0.size) > ($1.links, $1.size) })
        set(\.cleanup, CleanupReport.make(from: d))
        updateLogItems()
    }

    /// Builds the log rows from the report and the last log sizes.
    func updateLogItems() {
        set(\.logItems, logSizes.map { cleanup.logItems($0) } ?? .init())
    }

    func refreshRouting() async {
        routing = await Routing.status()
    }

    // MARK: - Auto-start / auto-stop

    /// Called by a proxy when a docker request arrives while the VM is down:
    /// start it and return once Docker is really ready. `profile` is the
    /// profile of a profile socket; nil means the selected profile (the
    /// stable socket). Two calls for the same profile share one wake.
    func wakeForProxy(profile target: String? = nil) async -> Bool {
        // An update swaps the bundle and restarts: a start now would run in
        // the copy that is about to quit. Wait for the restart (10 s at most,
        // in case it does not happen).
        for _ in 0..<100 where updateRestarting { try? await Task.sleep(for: .milliseconds(100)) }
        let p = target ?? profile
        if let running = wakes[p] { return await running.task.value }
        wakeToken += 1
        let token = wakeToken
        let task = Task { await performWake(p) }
        wakes[p] = (token, task)
        syncWakeHolds()
        let ok = await task.value
        if wakes[p]?.token == token {
            wakes[p] = nil
            syncWakeHolds()
        }
        if !ok, p == profile { set(\.startFailed, true) }
        return ok
    }

    /// Holds each proxy whose upstream profile has a wake that runs now: the
    /// stable proxy for the selected profile, and the profile proxies. Their
    /// requests then wait for that wake, whichever proxy started it.
    private func syncWakeHolds() {
        let h = Self.holds(waking: Set(wakes.keys), selected: profile)
        proxy.holdForWake(h.stable)
        profileProxies.holdForWake(h.profiles)
    }

    /// The runtime of a profile: the live value for the selected profile,
    /// else the one from the last `colima list`. "" when unknown.
    private func runtime(of p: String) -> String {
        p == profile ? vm.runtime : profiles.first { $0.name == p }?.runtime ?? ""
    }

    /// "The socket accepts connections" is not ready: Lima's ssh tunnel opens
    /// it seconds before dockerd, and Colima's provisioning restarts dockerd
    /// and containerd a few times. A request in that window fails with
    /// "Unavailable: error reading from server: EOF". So this waits for
    /// `colima start` to exit, then for several successes in a row on an
    /// endpoint that goes through containerd.
    private func performWake(_ p: String) async -> Bool {
        let probe = DockerAPI(socketPath: Paths.socket(p))
        let ready = ReadinessGate.dockerProbe(socketPath: Paths.socket(p))

        if readBusy(p) == nil, await ready() { return true }
        // A deleted profile: `colima start` would provision a new VM. A disk
        // shrink deletes colima.yaml for a short time, so check again after
        // the wait for a running action.
        func profileMissing() -> Bool {
            if p != "default", !FileManager.default.fileExists(atPath: Paths.config(p)) {
                Notifier.shared.post("Profile \(p) doesn't exist, so it wasn't started.")
                return true
            }
            return false
        }
        if readBusy(p) == nil, profileMissing() { return false }
        // Only the docker runtime has a docker socket to wait for.
        let rt = runtime(of: p)
        if !Self.hasDockerSocket(runtime: rt) {
            log.notice("profile \(p, privacy: .public) uses the \(rt, privacy: .public) runtime; not auto-starting")
            return false
        }
        func startInFlight() async -> Bool {
            if readBusy(p) != nil { return true }
            return await Task.detached { Self.colimaStartRunning(p) }.value
        }
        // A start/stop is already running (menu, auto-stop, a terminal): let it
        // finish instead of racing it.
        for _ in 0..<Self.startWaitSeconds {
            guard await startInFlight() else { break }
            try? await Task.sleep(for: .seconds(1))
        }
        var startedVersions: Task<ToolVersions, Never>?
        if !(await ready()) {
            if profileMissing() { return false }
            log.notice("auto-starting profile \(p, privacy: .public)")
            if p == profile { setBusyNow("Starting") } else { profileActions[p] = "Starting" }
            // The versions are read next to the start, so the wake waits no longer.
            let probed = Task { await probeVersions() }
            let r = await Shell.run(
                [Paths.ctl, CtlAction.start.rawValue], timeout: 600,
                extraEnv: ["COLIMABAR_PROFILE": p, "COLIMABAR_APP": "1"])
            if r.ok, UpgradeGuard.started(in: r.out) { startedVersions = probed }
            // The selected profile can change during the start.
            if p == profile, localBusy == "Starting" { localBusy = nil }
            if profileActions[p] == "Starting" { profileActions[p] = nil }
            if !r.ok { log.error("auto-start: colima-ctl.sh start exited \(r.status) for \(p, privacy: .public)") }
            checkDockerContext()
        }
        if await ReadinessGate.wait(probe: ready) {
            // Refresh the cached API version from the real daemon (a Colima
            // update can change it) before more pings are answered locally.
            if let v = await probe.get("/_ping", timeout: 3)?.headers["api-version"] {
                profileProxies.setAPIVersion(v, for: p)
                if p == profile {
                    proxy.apiVersion = v
                    profileProxies.apiVersion = v
                    Defaults.set(v, .apiVersion)
                }
            }
            Task { await refreshAll() }
            if let startedVersions { recordGoodWake(p, versions: await startedVersions.value) }
            return true
        }
        Notifier.shared.post("Colima profile \(p) didn't become ready. Check the Colima log.")
        return false
    }

    /// Makes one proxy and one `colimabar-PROFILE` context for each docker
    /// profile of the last `colima list`, and removes the ones of profiles
    /// that are gone. A debug run changes nothing. An empty list changes
    /// nothing either: it can come from a broken Colima install.
    private func syncProfiles() {
        guard !isDebug, !profiles.isEmpty else { return }
        pruneGoodStarts(keeping: Set(profiles.map(\.name)))
        pruneImageUpdateCache(keeping: Set(profiles.map(\.name)))
        let wanted = Set(
            profiles.filter { Self.hasDockerSocket(runtime: $0.runtime) && ProfileName.isValid($0.name) }.map(\.name))
        // A VM action can delete a profile for a short time (disk shrink):
        // keep its proxy until the action ends.
        let keep = profileProxies.names.filter { readBusy($0) != nil }
        profileProxies.sync(wanted: wanted, keep: keep)
        var hosts: [String: String] = [:]
        for p in profileProxies.names {
            if let path = profileProxies.path(for: p) { hosts[p] = "unix://\(path)" }
        }
        applyContexts(hosts)
    }

    /// Moves the docker CLI back to a ColimaBar context after Colima changed
    /// it (see `Routing.restoreContext`). Only while auto-start is on. One
    /// check runs at a time; a request during a check runs it again.
    private func checkDockerContext() {
        guard autoStart, !isDebug else { return }
        guard !isCheckingContext else {
            contextCheckAgain = true
            return
        }
        isCheckingContext = true
        Task {
            repeat {
                contextCheckAgain = false
                if await Routing.restoreContext(selected: profile) {
                    contextFailures = 0
                } else {
                    contextFailures += 1
                    contextRetryAt = Self.contextCheckRetryAt(failures: contextFailures, now: Date())
                }
            } while contextCheckAgain
            isCheckingContext = false
            if visibleCount > 0, dashboardTab == .system { routing = await Routing.status() }
        }
    }

    /// Applies the `colimabar-PROFILE` contexts in the background, one run at
    /// a time. A run applies the newest wanted set. After a failure, the same
    /// set runs again only after `contextsRetryInterval`.
    private func applyContexts(_ hosts: [String: String]) {
        if let f = contextsFailure,
            !Self.contextsRetryDue(wanted: hosts, failed: f.wanted, failedAt: f.at, now: Date())
        {
            return
        }
        wantedContexts = hosts
        guard !isApplyingContexts else { return }
        isApplyingContexts = true
        Task {
            while let want = wantedContexts, want != appliedContexts {
                wantedContexts = nil
                guard await ProfileContexts.apply(wanted: want) else {
                    contextsFailure = (want, Date())
                    break
                }
                contextsFailure = nil
                appliedContexts = want
            }
            isApplyingContexts = false
        }
    }

    /// Runs the weekly cleanup of the selected profile when it is due and the
    /// VM is idle. It never starts a VM: the script exits with 2 if the VM is down.
    func checkScheduledPrune() {
        if claimScheduledPrune(now: Date()) { runScheduledPrune(profile) }
    }

    /// True when a weekly cleanup of the selected profile starts now. It then
    /// holds the profile back for one hour, until the run sets the real wait.
    func claimScheduledPrune(now: Date) -> Bool {
        guard
            PruneSchedule.mayRun(
                enabled: scheduledPrune, isDebug: isDebug, updateRestarting: updateRestarting,
                running: state == .running, hasDockerSocket: hasDockerSocket, busyMarker: busy,
                actionsInFlight: busyActions(profile), waking: wakes[profile] != nil,
                transferring: volumeTransfer != nil, proxyTransfers: selectedTransfers(), trimming: isTrimming)
        else { return false }
        guard PruneSchedule.isDue(lastRun: pruneLastRun[profile], retryAt: pruneRetryAt[profile], now: now) else {
            return false
        }
        pruneRetryAt[profile] = now.addingTimeInterval(PruneSchedule.retryAfter)
        return true
    }

    /// The references that a registry check of the selected profile starts
    /// with now, or nil. The check then holds the profile back for an hour.
    /// `force` is Check Now: it skips the hourly gap and the 24 hours of each
    /// reference.
    func claimImageUpdates(now: Date, force: Bool = false) -> [ImageRef]? {
        guard
            ImageUpdateSchedule.mayRun(
                enabled: imageUpdateCheck, isDebug: isDebug, updateRestarting: updateRestarting,
                running: state == .running, hasDockerSocket: hasDockerSocket, busyMarker: busy,
                actionsInFlight: busyActions(profile), waking: wakes[profile] != nil,
                transferring: volumeTransfer != nil, proxyTransfers: selectedTransfers(), trimming: isTrimming,
                recreating: recreate != nil, checking: imageChecking),
            force || ImageUpdateSchedule.isDue(lastRun: imageRunAt[profile], now: now)
        else { return nil }
        let refs = ImageUpdateSchedule.plan(
            refs: imageUpdates.checkable, entries: imageUpdateCache.entries(of: profile), now: now, force: force)
        guard !refs.isEmpty else { return nil }
        imageRunAt[profile] = now
        return refs
    }

    /// Stops the VM once it has had no running containers for the chosen time.
    /// Builds, pulls and pushes show no running container, so live docker
    /// traffic through the proxies also counts as "not idle". Transfers count
    /// on the stable socket and on the socket of the selected profile.
    private func checkIdle() {
        // A debug run changes nothing: it must not stop the VM of the user.
        guard !isDebug else { return }
        // A check with a fresh list runs: a new evaluation would clear the idle
        // start that the check needs after the await.
        guard !isConfirmingAutoStop else { return }
        let now = SuspendingClock.now
        let limit = autoStopLimit
        let check = AutoStopRule.evaluate(
            enabled: autoStop, isRunning: state == .running,
            isBusy: Self.blocksAutoStop(busyMarker: busy, actionsInFlight: busyActions(profile)),
            runningContainers: running.count, transfers: selectedTransfers(), idleSince: idleStart, now: now,
            idleMinutes: limit.minutes)
        if check.idleSince != idleStart {
            idleStart = check.idleSince
            idleSince = check.idleSince == nil ? nil : Date()
        }
        let stopAt = check.idleSince.map {
            AutoStopRule.stopTime(idleSince: $0, now: now, wallNow: Date(), idleMinutes: limit.minutes)
        }
        if AutoStopRule.stopTimeMoved(old: autoStopAt, new: stopAt) { autoStopAt = stopAt }
        guard check.isDue else { return }
        // The list can be stale (events missed during a reconnect): confirm
        // with a fresh one right before stopping.
        isConfirmingAutoStop = true
        let gen = generation
        Task {
            defer { isConfirmingAutoStop = false }
            // No fresh list (timeout, error): don't stop on stale data.
            let fresh = await refreshContainers()
            guard fresh, gen == generation, autoStop, state == .running,
                !Self.blocksAutoStop(busyMarker: busy, actionsInFlight: busyActions(profile)),
                running.isEmpty, selectedTransfers() == 0, recreate == nil
            else {
                resetSelectedIdle()
                return
            }
            // The power state or the setting can change during the check.
            let current = autoStopLimit
            guard
                AutoStopRule.stillDue(idleSince: idleStart, now: SuspendingClock.now, minutes: current.minutes)
            else { return }
            resetSelectedIdle()
            log.notice(
                "auto-stopping idle profile \(self.profile, privacy: .public) after \(current.minutes, privacy: .public) min\(current.reason.map { " (\($0.note))" } ?? "", privacy: .public)"
            )
            run(.autoStop, "\(current.minutes)")
        }
    }

    /// Starts the idle time of the selected profile and of the others again.
    private func resetIdle() {
        resetSelectedIdle()
        otherIdle = [:]
    }

    private func resetSelectedIdle() {
        idleStart = nil
        set(\.idleSince, nil)
        set(\.autoStopAt, nil)
    }

    private func selectedTransfers() -> Int {
        proxy.activeTransfers() + profileProxies.activeTransfers(profile)
    }

    /// The auto-stop state of a running profile other than the selected one.
    private struct OtherIdle {
        var since: SuspendingClock.Instant?
        var lastCheck: Date?
        var isChecking = false
    }

    /// Auto-stop for each running docker profile other than the selected
    /// one, with the same rules and timeout. Work through the profile's proxy
    /// resets its idle time at each tick. Each `AutoStopRule.otherCheckInterval`,
    /// a fresh container list from the profile's own socket counts its
    /// running containers. A failed list does not count as idle.
    private func checkOtherProfilesIdle() {
        guard autoStop, !isDebug else {
            if !otherIdle.isEmpty { otherIdle = [:] }
            return
        }
        let names = AutoStopRule.otherProfiles(profiles, selected: profile)
        for p in otherIdle.keys where !names.contains(p) { otherIdle[p] = nil }
        let now = Date()
        for p in names {
            var s = otherIdle[p] ?? OtherIdle()
            guard !s.isChecking else { continue }
            if profileProxies.activeTransfers(p, now: now) > 0 || readBusy(p) != nil {
                s.since = nil
                otherIdle[p] = s
                continue
            }
            guard AutoStopRule.isCheckDue(lastCheck: s.lastCheck, now: now) else { continue }
            s.isChecking = true
            s.lastCheck = now
            otherIdle[p] = s
            let gen = generation
            let api = DockerAPI(socketPath: Paths.socket(p))
            Task {
                let count = await Self.runningContainerCount(api)
                // A profile switch or a settings change reset the state.
                guard gen == generation, var s = otherIdle[p] else { return }
                s.isChecking = false
                // Read the limit after the count: the power state can change during it.
                let limit = autoStopLimit
                let check = AutoStopRule.evaluate(
                    enabled: autoStop, isRunning: profiles.contains { $0.name == p && $0.isRunning } && p != profile,
                    isBusy: Self.blocksAutoStop(busyMarker: readBusy(p), actionsInFlight: busyActions(p)),
                    runningContainers: count, transfers: profileProxies.activeTransfers(p),
                    idleSince: s.since, now: .now, idleMinutes: limit.minutes)
                s.since = check.idleSince
                otherIdle[p] = check.isDue ? nil : s
                guard check.isDue else { return }
                // A VM type change runs: `run` would refuse and tell the user at each idle period.
                guard recreate == nil else { return }
                log.notice(
                    "auto-stopping idle profile \(p, privacy: .public) after \(limit.minutes, privacy: .public) min\(limit.reason.map { " (\($0.note))" } ?? "", privacy: .public)"
                )
                run(.autoStop, "\(limit.minutes)", profile: p)
            }
        }
    }

    /// When auto-stop stops each profile that is idle now, by profile: the
    /// selected profile and the other running profiles. The `colimabar`
    /// command reads it from the status file.
    func autoStopTimes() -> [String: Date] {
        var times: [String: Date] = [:]
        if let autoStopAt { times[profile] = autoStopAt }
        let minutes = autoStopLimit.minutes
        for (name, idle) in otherIdle {
            guard let since = idle.since else { continue }
            times[name] = AutoStopRule.stopTime(
                idleSince: since, now: .now, wallNow: Date(), idleMinutes: minutes)
        }
        return times
    }

    /// The number of running containers on a profile's socket, or nil if
    /// the request failed.
    nonisolated private static func runningContainerCount(_ api: DockerAPI) async -> Int? {
        guard let r = await api.get("/containers/json", timeout: 5), r.ok,
            let list = try? JSONDecoder().decode([APIContainer].self, from: r.body)
        else { return nil }
        return list.count
    }

    // MARK: - After system sleep

    /// The Mac is about to sleep: stop a check that still runs, so no ping
    /// runs into the sleep.
    private func systemSleepBegan() {
        afterSleep?.cancel()
        afterSleep = nil
        pauseNetworkChecks()
    }

    /// The Mac woke from sleep. The newest check wins.
    private func systemSleepEnded() {
        afterSleep?.cancel()
        afterSleep = Task { await recoverAfterSleep() }
    }

    /// A stream can hang after a sleep without an error, so open the streams
    /// again, refresh at once, and check each running VM.
    private func recoverAfterSleep() async {
        restartStreams()
        domainsAfterWake()
        await refreshAll()
        let blocked = Set(profiles.map(\.name).filter { isBlockedForSleepCheck($0) })
        let names = AfterSleepCheck.profiles(profiles, blocked: blocked)
        await withTaskGroup(of: Void.self) { group in
            for p in names { group.addTask { await self.checkAfterSleep(p) } }
        }
        // A new sleep cancels this run, and the pause stays.
        if !Task.isCancelled { resumeNetworkChecks() }
    }

    private func restartStreams() {
        events?.cancel()
        events = nil
        if state == .running { startEvents() }
        guard visibleCount > 0 else { return }
        for h in statStreams.values { h.cancel() }
        statStreams = [:]
        latest = [:]
        syncStatStreams()
    }

    /// An action, an auto-start or a busy marker: they report their own failures.
    func isBlockedForSleepCheck(_ p: String) -> Bool {
        Self.blocksSleepCheck(
            busyMarker: readBusy(p), actionsInFlight: actionsInFlight[p] ?? 0, starting: wakes[p] != nil)
    }

    /// False when the check of a profile must stop quietly.
    private func canCheckAfterSleep(_ p: String) -> Bool {
        !Task.isCancelled && !isBlockedForSleepCheck(p) && isRunning(profile: p)
    }

    /// Pings the Colima socket of the profile (never a proxy socket, so the
    /// check never starts a VM). If Docker answers, it checks the clock.
    /// If it does not, it sends one notification with a Restart button.
    private func checkAfterSleep(_ p: String) async {
        let api = DockerAPI(socketPath: Paths.socket(p))
        for delay in AfterSleepCheck.pingDelays {
            try? await Task.sleep(for: delay)
            guard canCheckAfterSleep(p) else { return }
            if await api.get("/_ping", timeout: AfterSleepCheck.pingTimeout)?.ok == true {
                // A new failure after this recovery must notify again.
                afterSleepAlerts.reset("no answer|\(p)")
                await syncClock(p, api)
                await checkPortsAfterWake(p)
                return
            }
        }
        guard canCheckAfterSleep(p) else { return }
        await refreshStatus()
        guard canCheckAfterSleep(p) else { return }
        log.error("docker does not answer in profile \(p, privacy: .public) after system sleep")
        guard afterSleepAlerts.allow("no answer|\(p)") else { return }
        Notifier.shared.post(AfterSleepCheck.noAnswerText(profile: p), restartProfile: p)
    }

    /// Measures the clock of the VM. If it is off, it waits for Lima to fix
    /// it, measures again, and sets the clock if it is still off. It sends a
    /// notification only if the clock is still off after that.
    private func syncClock(_ p: String, _ api: DockerAPI) async {
        guard !clockFixes.contains(p) else { return }
        let first: ClockDrift.Sample
        switch await Self.sampleClock(api) {
        case .success(let s): first = s
        case .failure(let e):
            log.error("no clock sample for profile \(p, privacy: .public): \(e.reason, privacy: .public)")
            return
        }
        guard ClockDrift.needsFix(first) else { return }
        log.notice("clock of profile \(p, privacy: .public) is off by \(first.offset, privacy: .public) s")
        try? await Task.sleep(for: ClockDrift.limaGrace)
        guard canCheckAfterSleep(p) else { return }
        let second: ClockDrift.Sample
        switch await Self.sampleClock(api) {
        case .success(let s): second = s
        case .failure(let e):
            log.error("no second clock sample for profile \(p, privacy: .public): \(e.reason, privacy: .public)")
            return
        }
        guard ClockDrift.needsFix(second) else {
            log.notice("clock of profile \(p, privacy: .public) is fine again")
            return
        }
        guard canCheckAfterSleep(p), !clockFixes.contains(p) else { return }
        clockFixes.insert(p)
        defer { clockFixes.remove(p) }
        let command = ClockDrift.fixCommand(profile: p, offset: second.offset)
        let r = await Shell.run(command, timeout: 20, includeStderr: true)
        if r.ok {
            log.notice("clock fix for profile \(p, privacy: .public) done")
        } else {
            let output = String(r.out.suffix(500))
            log.error(
                "clock fix for profile \(p, privacy: .public) exited \(r.status): \(output, privacy: .public)")
        }
        guard canCheckAfterSleep(p) else { return }
        let third: ClockDrift.Sample
        switch await Self.sampleClock(api) {
        case .success(let s): third = s
        case .failure(let e):
            log.error("no clock sample after the fix for profile \(p, privacy: .public): \(e.reason, privacy: .public)")
            return
        }
        guard ClockDrift.needsFix(third) else {
            log.notice("clock of profile \(p, privacy: .public) fixed")
            return
        }
        log.error("clock of profile \(p, privacy: .public) is still off by \(third.offset, privacy: .public) s")
        guard canCheckAfterSleep(p), afterSleepAlerts.allow("clock|\(p)") else { return }
        Notifier.shared.post(AfterSleepCheck.clockText(profile: p, offset: third.offset), restartProfile: p)
    }

    private struct ClockSampleError: Error { let reason: String }

    nonisolated private static func sampleClock(_ api: DockerAPI) async -> Result<ClockDrift.Sample, ClockSampleError> {
        let sent = Date()
        guard let r = await api.get("/info", timeout: 5) else { return .failure(.init(reason: "no reply")) }
        let received = Date()
        guard r.ok else { return .failure(.init(reason: "status \(r.status)")) }
        let info: APIInfo
        do { info = try JSONDecoder().decode(APIInfo.self, from: r.body) } catch {
            return .failure(.init(reason: "decode error: \(error.localizedDescription)"))
        }
        guard let time = info.SystemTime else { return .failure(.init(reason: "SystemTime missing")) }
        guard let sample = ClockDrift.sample(systemTime: time, sentAt: sent, receivedAt: received) else {
            return .failure(.init(reason: "SystemTime not valid: \(time)"))
        }
        return .success(sample)
    }

    /// What the Restart of an alert may do for a profile now.
    func alertRestartDecision(_ p: String) -> AlertRestart {
        let exists =
            (p == "default" || FileManager.default.fileExists(atPath: Paths.config(p)))
            && profiles.contains { $0.name == p }
        let blocked = isBlockedForSleepCheck(p) || (p == profile && busy != nil)
        return Self.alertRestart(exists: exists, blocked: blocked, running: isRunning(profile: p))
    }

    /// The Restart button of an after-sleep alert. It never starts a VM.
    func restartFromAlert(_ p: String) {
        switch alertRestartDecision(p) {
        case .restart: run(.restart, profile: p)
        case .missing: Notifier.shared.post(AfterSleepCheck.restartMissingText(profile: p))
        case .busy: Notifier.shared.post(AfterSleepCheck.restartBusyText(profile: p))
        case .stopped: Notifier.shared.post(AfterSleepCheck.restartStoppedText(profile: p))
        }
    }

    // MARK: - Live stats

    /// Only what the open tab needs: `colima list` when the last one is over
    /// a minute old, df for the disk tabs, and routing for the System tab.
    /// colima.yaml is a cheap read, so an edit outside the app shows at once.
    private func becameVisible() {
        reloadConfig()
        Task {
            if Date().timeIntervalSince(lastColima) >= Self.statusMaxAgeOnOpen { await refreshStatus() }
            if state == .running {
                await refreshContainers()
                requestDF(urgent: diskDirty)
            }
            if dashboardTab == .system { routing = await Routing.status() }
        }
        checkPortsOnOpen()
        syncStatStreams()
    }

    /// One `stats?stream=1` connection per running container while visible;
    /// the daemon pushes a sample each second with the previous one included,
    /// so CPU% needs no polling or bookkeeping on our side.
    private func syncStatStreams() {
        let want = visibleCount > 0 && state == .running ? Set(running.map(\.id)) : []
        for (id, h) in statStreams where !want.contains(id) {
            h.cancel()
            statStreams[id] = nil
            latest[id] = nil
        }
        let gen = generation
        for id in want where statStreams[id] == nil {
            statStreams[id] = api.stream(
                "/containers/\(id)/stats?stream=1",
                onLine: { [weak self] line in
                    guard let s = try? JSONDecoder().decode(APIStats.self, from: line) else { return }
                    let stat = Stat(cpu: s.cpuPercent, memBytes: s.memBytes)
                    Task { @MainActor in
                        guard let self, self.generation == gen else { return }
                        self.latest[id] = stat
                    }
                },
                onEnd: { [weak self] handle in
                    Task { @MainActor in
                        // Only clear the entry if it's still this stream, not a newer one.
                        guard let self, self.generation == gen, self.statStreams[id] === handle else { return }
                        self.statStreams[id] = nil
                        self.latest[id] = nil
                    }
                })
        }
        if want.isEmpty { set(\.stats, [:]) }
    }

    private func publishStats() {
        set(\.stats, latest)
        guard state == .running else { return }
        let cpu = latest.values.reduce(0) { $0 + $1.cpu } / Double(max(vm.cpus, 1))
        let vmBytes = (vm.memGB > 0 ? vm.memGB : 1) * Double(ByteFormat.bytesPerGiB)
        let mem = latest.values.reduce(0) { $0 + $1.memBytes } / vmBytes * 100
        push(&cpuHistory, min(cpu, 100))
        push(&memHistory, min(mem, 100))
    }

    // MARK: - Events

    private func startEvents() {
        guard hasDockerSocket else { return }
        let filters = DockerAPI.percentEncoded(Self.eventFilter)
        let gen = generation
        events = api.stream(
            "/events?filters=\(filters)",
            onLine: { [weak self] line in
                guard let ev = try? JSONDecoder().decode(DockerEvent.self, from: line),
                    !Self.ignores(action: ev.Action ?? "")
                else { return }
                Task { @MainActor in
                    guard let self, self.generation == gen else { return }
                    self.handle(ev)
                }
            },
            onEnd: { [weak self] handle in
                // VM stopped or socket hiccup: the heartbeat's ping reconnects.
                Task { @MainActor in
                    guard let self, self.generation == gen, self.events === handle else { return }
                    self.events = nil
                }
            })
        // Events that happened while no stream was open are lost: reload the
        // list so a container started in that gap isn't missed.
        Task { await refreshContainers() }
    }

    private func handle(_ ev: DockerEvent) {
        let attrs = ev.Actor?.Attributes ?? [:]
        let action = ev.Action ?? ""
        // Stats/exec events fire constantly and change nothing we show.
        if Self.ignores(action: action) { return }
        // testcontainers' containers are torn down (often non-zero) on every
        // test run; their failures already show up in the test output.
        let isTestcontainer = attrs["org.testcontainers"] == "true"
        // A debug shell container ends with the exit code of its shell: that is no crash.
        // The helper container of a volume backup never runs, but it is no crash either.
        let isDebugSidecar = Self.isInternalContainer(name: attrs["name"], attributes: attrs)
        if ev.Type == "container", !isTestcontainer, !isDebugSidecar {
            reactToContainerEvent(ev, attrs: attrs, notify: notifyOnCrash)
        }
        let reaction = Self.reaction(type: ev.Type ?? "", action: action)
        if reaction.contains(.savedLogs), !isDebugSidecar, let id = ev.Actor?.ID {
            keeper.event(action: action, id: id, attributes: attrs)
        }
        if reaction.contains(.disk) { diskDirty = true }
        guard !reaction.isEmpty else { return }
        if reaction.contains(.containers) { reloadPending = true }
        // Coalesce a burst of events (compose up/down) into one refresh.
        containerRefresh?.cancel()
        containerRefresh = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            if reloadPending {
                reloadPending = false
                await refreshContainers()
            }
            if diskDirty { requestDF() }
        }
    }

    // MARK: - Actions

    /// Runs a colima-ctl.sh action (it owns confirm dialogs, config edits,
    /// the busy marker and notifications), then refreshes. `profile` is the
    /// profile to act on; nil means the selected profile.
    func run(_ action: CtlAction, _ args: String..., profile target: String? = nil) {
        run(action, args: args, profile: target)
    }

    /// Like `run(_:_:profile:)` with the arguments in an array.
    func run(_ action: CtlAction, args: [String], profile target: String? = nil) {
        // The old copy quits at once after the swap of an update.
        guard !updateRestarting else { return }
        // The backups and the restore of a VM type change need the VM as it is.
        if recreate != nil {
            notify(Help.recreateBusy)
            return
        }
        if action == .diskShrink || action == .vmRecreate, volumeTransfer != nil {
            notify(
                action == .diskShrink
                    ? "Wait until the volume backup or restore ends, then shrink the disk."
                    : "Wait until the volume backup or restore ends, then change the VM type.")
            return
        }
        let p = target ?? profile
        let running = isRunning(profile: p)
        if action.showsDialog(running: running) { dismissPopover() }
        let label = markBusy(action, p, running: running)
        Task { await execute(action, args, profile: p, label: label, expectRunning: running) }
    }

    /// Shows the busy label at once, not on the next tick, so a second click
    /// can't race the action. The selected profile shows it in the header,
    /// another profile in the profile menu.
    func markBusy(_ action: CtlAction, _ p: String, running: Bool? = nil) -> String? {
        guard let label = action.busyLabel(running: running ?? isRunning(profile: p)) else { return nil }
        if p == profile { setBusyNow(label) } else { profileActions[p] = label }
        return label
    }

    /// Returns true if the script exited with 0. `expectRunning` is the VM
    /// state that `run` used to decide on the popover and the busy label.
    @discardableResult
    func execute(
        _ action: CtlAction, _ args: [String], profile p: String, label: String?, expectRunning: Bool? = nil
    ) async -> Bool {
        await executeResult(action, args, profile: p, label: label, expectRunning: expectRunning).ok
    }

    /// Like `execute`, and returns the result of the script, so a caller can
    /// read its exit status and its output.
    @discardableResult
    func executeResult(
        _ action: CtlAction, _ args: [String], profile p: String, label: String?, expectRunning: Bool? = nil
    ) async -> Shell.Result {
        actionsInFlight[p, default: 0] += 1
        defer { actionsInFlight[p, default: 1] -= 1 }
        // A VM-wide stop sends no `kill` event for each container. The event
        // stream is the one of the selected profile.
        let holdsAlerts = action.stopsContainers && p == profile
        if holdsAlerts { alertGate.holdAll() }
        // A profile switch makes a new gate: it must not get this release.
        let holdGeneration = generation
        defer { if holdsAlerts, generation == holdGeneration { alertGate.releaseAll(now: Date()) } }
        // A start of a profile is good when the script exits with 0 and prints
        // the marker of a start. A warning action reads the versions first: a
        // risky change since the last good start makes the script ask. Another
        // start action reads them next to the script, so it waits no longer.
        let running = expectRunning ?? false
        let starts = action.startsVM(running: running)
        let warns = action.warnsAfterUpgrade(running: running)
        var versions: ToolVersions?
        var upgrade: (note: String, releaseNotes: [URL])?
        var probed: Task<ToolVersions, Never>?
        if warns {
            let now = await probeVersions()
            versions = now
            upgrade = UpgradeGuard.warning(
                action: action, running: running, profile: p, last: goodStart(for: p), now: now)
            if upgrade != nil { dismissPopover() }
        } else if starts {
            probed = Task { await probeVersions() }
        }
        let env = action.environment(profile: p, expectRunning: expectRunning, upgrade: upgrade)
        let r = await Shell.run([Paths.ctl, action.rawValue] + args, timeout: action.timeout, extraEnv: env)
        if let probed { versions = await probed.value }
        if starts, r.ok, UpgradeGuard.started(in: r.out), let versions { saveGoodStart(versions, p) }
        // colima-ctl.sh reports failures as "COLIMABAR_NOTIFY:<message>"
        // lines when ColimaBar runs it, so they arrive as native alerts.
        let notices = Self.notices(in: r.out)
        for text in notices { Notifier.shared.post(text) }
        let notified = !notices.isEmpty
        // Exit 2 = the user cancelled a confirm dialog or another action holds the lock.
        if p == profile, r.status != 2, action == .start || action == .restart || action == .repair {
            set(\.startFailed, !r.ok)
        }
        if !r.ok, !notified, r.status != 2 {
            Notifier.shared.post(
                "\(action.rawValue) failed for profile \(p) (exit \(r.status)). See \(Paths.ctlLog).")
        }
        // A config edit of a stopped VM wrote colima.yaml. Read it before
        // "Saving" ends: refreshAll reads it only after a good `colima list`.
        // Else a switch snaps back, and Apply turns on with the old pick.
        if action.editsConfigWhenStopped, expectRunning == false, p == profile { reloadConfig() }
        // The action is over (done, failed or cancelled): drop the
        // placeholder, but only if a newer action hasn't replaced it.
        if p == profile, localBusy == label { localBusy = nil }
        if let label, profileActions[p] == label { profileActions[p] = nil }
        busy = readBusy()
        await refreshAll(urgentDF: action.changesDisk)
        // Colima switches the docker context on start and deletes it on stop.
        if action.isVMAction, r.status != 2 {
            checkDockerContext()
            forgetNetworkHealth(p)
        }
        return r
    }

    /// The messages of the `COLIMABAR_NOTIFY:<message>` lines in the output
    /// of colima-ctl.sh.
    nonisolated static func notices(in output: String) -> [String] {
        let prefix = "COLIMABAR_NOTIFY:"
        return output.split(separator: "\n").filter { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }
    }

    /// Doctor publishes through these two, because the properties are
    /// `private(set)` and Doctor lives in `ColimaModel+Doctor`.
    func publishDoctor(report: DoctorReport?) {
        if doctorReport != report { doctorReport = report }
    }

    func setDoctorRunning(_ on: Bool) { set(\.isDoctorRunning, on) }

    /// `ColimaModel+NetworkHealth` stores its checks through these two.
    func setPortHealth(_ all: [String: PortHealth.Report]) { set(\.portHealth, all) }
    func setDNSHealth(_ all: [String: DNSHealth.Report]) { set(\.dnsHealth, all) }
    func setNetworkChecking(_ all: Set<String>) { set(\.networkChecking, all) }
    func setNetworkCheckErrors(_ all: [String: String]) { set(\.networkCheckErrors, all) }

    /// `ColimaModel+Compose` stores its state through these two.
    func setComposeBusy(_ all: Set<String>) { set(\.composeBusy, all) }
    func setImageUpdates(_ state: ImageUpdateState) { set(\.imageUpdates, state) }
    func setComposeOutput(_ lines: [String], key: String) { composeOutput[key] = lines }
    func setComposeIssues(_ missing: Set<String>, hasDocker: Bool) {
        set(\.composeMissing, missing)
        set(\.composeNoDocker, !hasDocker)
    }

    /// `ColimaModel+Diagnostics` sets the flag through this function.
    func setSavingDiagnostics(_ on: Bool) { set(\.isSavingDiagnostics, on) }
    func setVolumeTransfer(_ transfer: VolumeTransfer?) {
        set(\.volumeTransfer, transfer)
        // A VM type change shows the backup and the restore in its own strip.
        guard let t = transfer, var r = recreate, r.step == .backingUp || r.step == .restoring else { return }
        r.volume = t.volume
        r.bytes = t.bytes
        r.total = t.total
        r.position = t.position ?? r.position
        r.count = t.position == nil ? r.count : t.count
        r.isCancelling = t.isCancelling || r.isCancelling
        set(\.recreate, r)
    }

    /// `ColimaModel+VMRecreate` stores its state through these.
    func setRecreate(_ progress: VMRecreateProgress?) { set(\.recreate, progress) }
    func setPendingRecreate(_ all: [String: VMRecreateJournal]) { set(\.pendingRecreate, all) }
    /// For tests: a colima.yaml read without a file.
    func setVMSettings(_ read: VMSettings.Read?) { set(\.vmSettings, read) }
    /// A VM type change holds the actions of its profile, so auto-stop and the
    /// weekly cleanup stay away while it runs.
    func holdAction(_ p: String) { actionsInFlight[p, default: 0] += 1 }
    func releaseAction(_ p: String) { actionsInFlight[p, default: 1] -= 1 }

    /// `ColimaModel+Cleanup` stores its state through these.
    func setLogSizes(_ sizes: [String: Int64]?, error: String?) {
        set(\.logSizes, sizes)
        set(\.logSizesError, error)
        updateLogItems()
    }
    func setState(_ s: VMState) { set(\.state, s) }

    /// `ColimaModel+Domains` stores its state through these two.
    func setDomainRoutes(_ routes: DomainRoutes) { set(\.domainRoutes, routes) }
    func setDomainStatus(_ status: DomainStatus) { set(\.domainStatus, status) }
    func setDomainRestartHints(_ hints: [DomainRestartHint]) { set(\.domainRestartHints, hints) }
    func setDomainSuffixValue(_ suffix: String?) { set(\.domainSuffix, suffix) }
    func setHTTPSEnabledFlag(_ on: Bool) { set(\.httpsEnabled, on) }
    func setLogSizesChecking(_ on: Bool) { set(\.logSizesChecking, on) }
    func setDiskImage(_ size: DiskImageSize?) { set(\.diskImage, size) }
    func setTrimming(_ on: Bool) { set(\.isTrimming, on) }
    /// Saves the time of a weekly cleanup of a profile.
    func savePruneRun(_ p: String, at date: Date) {
        var runs = pruneLastRun
        runs[p] = date
        Defaults.set(PruneSchedule.encode(runs), .scheduledPruneLastRun)
        set(\.pruneLastRun, runs)
    }

    // MARK: - Profiles

    /// Starts the VM of a profile, also of the selected one.
    func startProfile(_ p: String) { run(.start, profile: p) }

    /// Stops the VM of a profile, also of the selected one.
    func stopProfile(_ p: String) { run(.stop, profile: p) }

    /// The profile menu offers Start for this profile.
    func canStart(profile p: String) -> Bool {
        Self.profileAction(
            start: true, isSelected: p == profile, state: state,
            listedRunning: profiles.first { $0.name == p }?.isRunning ?? false,
            busy: p == profile ? busy != nil : profileActions[p] != nil)
    }

    /// The profile menu offers Stop for this profile.
    func canStop(profile p: String) -> Bool {
        Self.profileAction(
            start: false, isSelected: p == profile, state: state,
            listedRunning: profiles.first { $0.name == p }?.isRunning ?? false,
            busy: p == profile ? busy != nil : profileActions[p] != nil)
    }

    /// Creates a profile and starts its VM. The directory watcher then
    /// lists it, and it gets its proxy and its docker context.
    func createProfile(_ form: NewProfileForm) {
        if let problem = form.problem(
            existing: profiles.map(\.name), qemuInstalled: VMTypeRules.qemuInstalled(arch: ""))
        {
            Notifier.shared.post(problem)
            return
        }
        let label = markBusy(.profileCreate, form.name)
        Task { await execute(.profileCreate, form.arguments, profile: form.name, label: label) }
    }

    /// True while the VM of the profile runs. Right after a switch, the
    /// state of the selected profile is unknown: then the last `colima list`
    /// decides, and a profile that it does not show counts as running.
    func isRunning(profile p: String) -> Bool {
        let row = profiles.first { $0.name == p }
        guard p == profile else { return row?.isRunning ?? false }
        return Self.selectedIsRunning(state: state, listed: row?.isRunning)
    }

    /// Deletes a profile with its VM and data. A running selected profile
    /// must stop first. After the delete, its proxy socket and its
    /// `colimabar-PROFILE` context go away. If it was selected, the
    /// dashboard switches to `default`.
    func deleteProfile(_ p: String) {
        // An action of the profile can start while the confirmation is open.
        if readBusy(p) != nil || profileActions[p] != nil || (p == profile && busy != nil) {
            Notifier.shared.post("Wait until the action of the profile \(p) ends, then delete it.")
            return
        }
        if volumeTransfer != nil || recreate != nil {
            Notifier.shared.post(
                "Wait until the volume backup, restore or VM type change ends, then delete the profile \(p).")
            return
        }
        if let refusal = ProfileDelete.refusal(profile: p, selected: profile, isRunning: isRunning(profile: p)) {
            Notifier.shared.post(refusal)
            return
        }
        let label = markBusy(.profileDelete, p)
        Task {
            guard await execute(.profileDelete, [], profile: p, label: label) else { return }
            if !isDebug {
                profileProxies.remove(p)
                appliedContexts?[p] = nil
                await ProfileContexts.remove(profile: p)
            }
            let next = ProfileDelete.nextSelection(deleted: p, selected: profile, remaining: profiles.map(\.name))
            if next != profile { profile = next }
        }
    }

    private func setBusyNow(_ label: String) {
        localBusy = label
        if busy == nil { busy = label }
        // The heartbeat runs each second now, not after a long sleep.
        wakeHeartbeat()
    }

    func record(_ title: String, _ body: String, containerID: String?) {
        alerts.insert(AlertItem(title: title, body: body, containerID: containerID), at: 0)
        if alerts.count > Self.alertCap { alerts.removeLast(alerts.count - Self.alertCap) }
    }

    func clearAlerts() {
        alerts.removeAll()
    }

    func container(withID id: String) -> Container? { containers.first { $0.id == id } }

    /// Client for a profile's socket: the live one for the selected profile.
    private func api(for p: String) -> DockerAPI {
        p == profile ? api : DockerAPI(socketPath: Paths.socket(p))
    }

    /// Container lifecycle calls that need no confirmation go straight to the API.
    /// The timeout covers containers with a long stop grace period.
    func container(_ id: String, _ verb: ContainerVerb, profile p: String? = nil) {
        let client = api(for: p ?? profile)
        Task {
            let r = await client.post("/containers/\(id)/\(verb.rawValue)", timeout: verb == .start ? 60 : 180)
            if !(r?.ok ?? false) {
                let msg = r.flatMap { try? JSONDecoder().decode([String: String].self, from: $0.body)["message"] }
                Notifier.shared.post("\(verb.rawValue.capitalized) failed: \(msg ?? "no response from Docker")")
            }
            await refreshContainers()
        }
    }

    /// stop|start|restart every container of a compose project. At most
    /// `projectConcurrency` requests run at once: each one holds a thread
    /// for up to 180 s.
    func project(_ name: String, _ verb: ContainerVerb) {
        let ids = containers.filter {
            $0.project == name && (verb == .start ? !$0.isRunning : $0.isRunning || verb == .restart)
        }
        .map(\.id)
        let names = Dictionary(uniqueKeysWithValues: containers.map { ($0.id, $0.name) })
        Task { [api] in
            let failed = await Self.failures(ids, limit: Self.projectConcurrency) { id in
                let r = await api.post("/containers/\(id)/\(verb.rawValue)", timeout: 180)
                return (r?.ok ?? false) ? nil : names[id] ?? String(id.prefix(12))
            }
            if !failed.isEmpty {
                Notifier.shared.post(
                    "\(verb.rawValue.capitalized) failed for \(failed.sorted().joined(separator: ", ")).")
            }
            await refreshContainers()
        }
    }

    /// Opens the log window. If the container is gone and `keeper` saved
    /// its last lines, the window shows them instead of live logs.
    func openLogs(id: String, name: String, profile p: String? = nil) {
        let target = p ?? profile
        let keeper = self.keeper
        let saved: (@MainActor () -> [LogLine]?)? =
            target == profile ? { @MainActor [weak keeper] in keeper?.saved(id) } : nil
        LogWindows.shared.open(api: api(for: target), id: id, name: name, savedLines: saved) { [weak self] in
            self?.terminal(.containerLogs, name, profile: target)
        }
    }

    /// Runs a colima-ctl.sh action in a terminal window.
    func terminal(_ action: CtlAction, _ args: String..., profile p: String? = nil) {
        let words = [Paths.ctl, action.rawValue] + args
        // The same Colima folder as the app, also when the shell sets COLIMA_HOME.
        Shell.inTerminal(
            "COLIMA_HOME=\(Shell.quote(Paths.preparedColimaDir())) COLIMABAR_PROFILE=\(Shell.quote(p ?? profile)) "
                + words.map(Shell.quote).joined(separator: " "))
    }

    func open(port: Int) {
        if let u = URL(string: "http://localhost:\(port)") { NSWorkspace.shared.open(u) }
    }

    /// The `colimabar` command has no notifications: it must not touch
    /// `Notifier`. It writes its messages to the terminal.
    func notify(_ msg: String) {
        if let notifySink {
            notifySink(msg)
            return
        }
        guard !AppDelegate.isCommandLine else { return }
        Notifier.shared.post(msg)
    }

    // MARK: - Helpers

    func set<T: Equatable>(_ kp: ReferenceWritableKeyPath<ColimaModel, T>, _ v: T) {
        if self[keyPath: kp] != v { self[keyPath: kp] = v }
    }

    private func push(_ arr: inout [Double], _ v: Double) {
        arr.append(v)
        if arr.count > historyLen { arr.removeFirst(arr.count - historyLen) }
    }
}
