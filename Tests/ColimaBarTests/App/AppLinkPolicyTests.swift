import Testing

@testable import ColimaBar

@Suite struct AppLinkPolicyTests {
    private typealias Facts = AppLinkPolicy.Facts

    private func decide(_ action: AppLink.VMAction, _ facts: Facts) -> AppLinkPolicy.Outcome {
        AppLinkPolicy.decide(action, facts)
    }

    @Test func aRunningVMStopsAndRestarts() {
        let facts = Facts(running: true)
        #expect(decide(.stop, facts) == .run)
        #expect(decide(.restart, facts) == .run)
    }

    @Test func aStoppedVMStarts() {
        #expect(decide(.start, Facts(running: false)) == .run)
    }

    @Test func gatesApplyInOrder() {
        var facts = Facts(
            updating: true, colimaMissing: true, listFailed: true, profileExists: false, busy: true, running: false)
        #expect(decide(.restart, facts) == .refuse(.updating))
        facts.updating = false
        #expect(decide(.restart, facts) == .refuse(.colimaMissing))
        facts.colimaMissing = false
        #expect(decide(.restart, facts) == .refuse(.listFailed))
        facts.listFailed = false
        #expect(decide(.restart, facts) == .refuse(.profileMissing))
        facts.profileExists = true
        #expect(decide(.restart, facts) == .refuse(.busy))
        facts.busy = false
        #expect(decide(.restart, facts) == .refuse(.stopped))
    }

    @Test func busyComesBeforeState() {
        #expect(decide(.start, Facts(busy: true, running: true)) == .refuse(.busy))
        #expect(decide(.stop, Facts(busy: true, running: false)) == .refuse(.busy))
    }

    @Test func startOfARunningVMAndStopOfAStoppedVMDoNothing() {
        #expect(decide(.start, Facts(running: true)) == .nothing)
        #expect(decide(.stop, Facts(running: false)) == .nothing)
    }

    @Test func aLinkNeverCreatesAProfile() {
        for action in AppLink.VMAction.allCases {
            #expect(decide(action, Facts(profileExists: false)) == .refuse(.profileMissing))
        }
    }

    @Test func onlyVMLinksAsk() {
        #expect(AppLinkPolicy.asks(.vm(.start, profile: nil), setting: true))
        #expect(AppLinkPolicy.asks(.vm(.stop, profile: "w"), setting: true))
        #expect(AppLinkPolicy.asks(.vm(.restart, profile: nil), setting: true))
        #expect(!AppLinkPolicy.asks(.open, setting: true))
        #expect(!AppLinkPolicy.asks(.doctor, setting: true))
    }

    @Test func nothingAsksWhileTheSettingIsOff() {
        #expect(!AppLinkPolicy.asks(.vm(.stop, profile: nil), setting: false))
    }

    @Test func refusalTexts() {
        let t = { (r: AppLinkPolicy.Refusal, a: AppLink.VMAction) in
            AppLinkPolicy.text(for: r, action: a, profile: "work")
        }
        #expect(t(.profileMissing, .start) == "Profile work doesn't exist, so it wasn't started.")
        #expect(t(.profileMissing, .stop) == "Profile work doesn't exist, so it wasn't stopped.")
        #expect(t(.profileMissing, .restart) == "Profile work doesn't exist, so it wasn't restarted.")
        #expect(t(.busy, .start) == AfterSleepCheck.restartBusyText(profile: "work"))
        #expect(t(.stopped, .restart) == AfterSleepCheck.restartStoppedText(profile: "work"))
        #expect(
            t(.updating, .start) == "ColimaBar restarts for an update now. Try the link again in a few seconds.")
        #expect(
            t(.colimaMissing, .start)
                == "Colima isn't installed, so ColimaBar did not run the link. Install it with Homebrew: brew install colima docker"
        )
        #expect(
            t(.listFailed, .start)
                == "ColimaBar could not read the Colima profiles, so it did not run the link. Try again.")
    }

    @Test func parseFailureTexts() {
        let usage = "ColimaBar cannot use this link. Use colimabar://open, doctor, start, stop or restart."
        for f in [AppLink.Failure.tooLong, .malformed, .wrongScheme, .unknownRoute] {
            #expect(AppLinkPolicy.text(for: f) == usage)
        }
        #expect(
            AppLinkPolicy.text(for: .badParameter)
                == "ColimaBar cannot use this link. Only start, stop and restart take a parameter: profile=NAME.")
        #expect(
            AppLinkPolicy.text(for: .badProfile)
                == "The profile name in the link is not valid. Use a name that colima list shows.")
    }

    @Test func dialogs() {
        let start = AppLinkPolicy.dialog(.start, profile: "w")
        let stop = AppLinkPolicy.dialog(.stop, profile: "w")
        let restart = AppLinkPolicy.dialog(.restart, profile: "w")
        #expect(
            start
                == AppLinkPolicy.Dialog(
                    title: "Start the VM of profile 'w'?",
                    text:
                        "A link from another app or a web page asks to start this VM. The VM uses memory and battery while it runs.",
                    button: "Start", destructive: false))
        #expect(
            stop
                == AppLinkPolicy.Dialog(
                    title: "Stop the VM of profile 'w'?",
                    text: "A link from another app or a web page asks to stop this VM. Its running containers stop.",
                    button: "Stop", destructive: true))
        #expect(
            restart
                == AppLinkPolicy.Dialog(
                    title: "Restart the VM of profile 'w'?",
                    text:
                        "A link from another app or a web page asks to restart this VM. Running containers stop. Only containers with a restart policy start again.",
                    button: "Restart", destructive: true))
        #expect(AppLinkPolicy.suppressionTitle == "Do not ask again for links")
    }

    // MARK: - Facts

    private let rows = [
        ProfileRow(name: "default", isRunning: true, cpus: 2, memGB: 2),
        ProfileRow(name: "work", isRunning: false, cpus: 2, memGB: 2),
    ]

    private func facts(
        _ profile: String, updating: Bool = false, missing: Bool = false, listed: Bool = true, busy: String? = nil
    ) -> Facts {
        AppLinkPolicy.facts(
            profile: profile, profiles: rows, updating: updating, colimaMissing: missing, listed: listed,
            busyMarker: busy)
    }

    @Test func factsReadTheProfileRow() {
        #expect(facts("default") == Facts(running: true))
        #expect(facts("work") == Facts(running: false))
    }

    @Test func factsOfAnUnknownProfileSayItIsMissing() {
        #expect(facts("other") == Facts(profileExists: false, running: false))
    }

    @Test func factsCarryTheBusyMarkerTheMissingColimaAndAFailedList() {
        #expect(facts("work", busy: "starting").busy)
        #expect(facts("work", missing: true).colimaMissing)
        #expect(facts("work", listed: false).listFailed)
    }

    @Test func anUpdateHidesEveryOtherFact() {
        #expect(facts("other", updating: true, missing: true, listed: false, busy: "x") == Facts(updating: true))
    }

    @Test func theListIsReadAgainOnlyWhenColimaIsThere() {
        #expect(AppLinkPolicy.needsSecondRead(listed: false, colimaMissing: false))
        #expect(!AppLinkPolicy.needsSecondRead(listed: false, colimaMissing: true))
        #expect(!AppLinkPolicy.needsSecondRead(listed: true, colimaMissing: false))
    }

    @Test func aFailureGoesToAnAlertOnlyWhenNotificationsAreOff() {
        #expect(AppLinkPolicy.channel(notificationsAllowed: true) == .notification)
        #expect(AppLinkPolicy.channel(notificationsAllowed: false) == .alert)
    }
}
