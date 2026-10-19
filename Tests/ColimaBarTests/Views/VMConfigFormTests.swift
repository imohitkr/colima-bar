import Testing

@testable import ColimaBar

@MainActor @Suite struct VMConfigFormTests {
    private func loaded(_ read: VMSettings.Read = VMSettings.Read()) -> VMConfigForm {
        let form = VMConfigForm()
        form.load(read, sha: "aa", profile: "work")
        return form
    }

    @Test func aLoadedFormIsNotDirty() {
        var read = VMSettings.Read()
        read.dnsServers = ["1.1.1.1"]
        read.mounts = [VMMount(location: "~", writable: true)]
        let form = loaded(read)
        #expect(!form.isDirty && form.change.isEmpty)
        #expect(form.dnsText == "1.1.1.1" && form.profile == "work")
    }

    @Test func theChangeHoldsOnlyTheFieldsThatDiffer() {
        let form = loaded()
        form.dnsText = "1.1.1.1, 8.8.8.8"
        form.portForwarder = "grpc"
        #expect(form.change == VMSettingsChange(dnsServers: ["1.1.1.1", "8.8.8.8"], portForwarder: "grpc"))
        #expect(form.isDirty)
    }

    @Test func revertGoesBackToTheFile() {
        let form = loaded()
        form.dnsText = "1.1.1.1"
        form.address = true
        form.mountInotify = true
        form.addMount("~/code")
        form.mirrorsText = "https://m.example.com"
        form.revert()
        #expect(!form.isDirty)
        #expect(form.dnsText.isEmpty && !form.address && form.mounts.isEmpty && form.mirrorsText.isEmpty)
    }

    @Test func aValueThatReturnsToTheFileIsNoChange() {
        let form = loaded()
        form.dnsText = "1.1.1.1"
        form.dnsText = ""
        #expect(!form.isDirty)
    }

    @Test(arguments: [
        ("1.1.1.1,8.8.8.8", ["1.1.1.1", "8.8.8.8"]), ("1.1.1.1  8.8.8.8", ["1.1.1.1", "8.8.8.8"]),
        (" 1.1.1.1 , ,8.8.8.8, ", ["1.1.1.1", "8.8.8.8"]), ("", []), ("  ", []),
    ])
    func aTextSplitsAtCommasAndBlanks(text: String, items: [String]) {
        #expect(VMConfigForm.items(text) == items)
    }

    @Test func theFirstFolderOfAnEmptyListComesAfterTheHomeFolder() {
        var read = VMSettings.Read()
        read.mountsDefaultHome = true
        let form = loaded(read)
        form.addMount("/Volumes/Data")
        #expect(form.mounts == [VMMount(location: "~", writable: true), VMMount(location: "/Volumes/Data")])
        form.addMount("/Volumes/More")
        #expect(form.mounts.count == 3)
    }

    @Test func aFolderThatIsInTheListIsNotAddedTwice() {
        var read = VMSettings.Read()
        read.mounts = [VMMount(location: "~/code")]
        let form = loaded(read)
        form.addMount("~/code")
        #expect(form.mounts.count == 1 && !form.isDirty)
    }

    @Test func removingTheLastFolderGivesAnEmptyList() {
        var read = VMSettings.Read()
        read.mounts = [VMMount(location: "~/code")]
        let form = loaded(read)
        form.removeMount(at: 0)
        form.removeMount(at: 5)
        #expect(form.change == VMSettingsChange(mounts: []))
    }

    @Test func aReadOnlyFieldNeverGoesInTheChange() {
        var read = VMSettings.Read()
        read.readOnly = [.dnsServers, .mounts]
        let form = loaded(read)
        form.dnsText = "1.1.1.1"
        form.addMount("/Volumes/Data")
        form.mountInotify = true
        #expect(form.change == VMSettingsChange(mountInotify: true))
    }

    @Test func loadingAgainDropsTheEdits() {
        let form = loaded()
        form.dnsText = "1.1.1.1"
        var read = VMSettings.Read()
        read.portForwarder = "grpc"
        form.load(read, profile: "other")
        #expect(form.dnsText.isEmpty && form.portForwarder == "grpc" && form.profile == "other")
    }

    @Test func theFirstFolderOfAFileWithNoMountsGoesInAlone() {
        let form = loaded()
        #expect(!form.emptyListMountsHome)
        form.addMount("/Volumes/Data")
        #expect(form.mounts == [VMMount(location: "/Volumes/Data")])
    }

    @Test func aFolderAfterTheLastOneWasRemovedComesAfterTheHomeFolder() {
        var read = VMSettings.Read()
        read.mounts = [VMMount(location: "~/code")]
        let form = loaded(read)
        form.removeMount(at: 0)
        #expect(form.emptyListMountsHome)
        form.addMount("/Volumes/Data")
        #expect(form.mounts.first == VMMount(location: "~", writable: true))
    }

    @Test func aFormWithNothingEditedReloadsForAChangedFile() {
        let form = loaded()
        var read = VMSettings.Read()
        read.dnsServers = ["9.9.9.9"]
        #expect(form.shouldReload(for: read, profile: "work"))
    }

    @Test func aFormWithEditsKeepsThemForAChangedFile() {
        let form = loaded()
        form.dnsText = "1.1.1.1"
        var read = VMSettings.Read()
        read.portForwarder = "grpc"
        #expect(!form.shouldReload(for: read, profile: "work"))
    }

    @Test func aFormWithEditsReloadsForAnotherProfile() {
        let form = loaded()
        form.dnsText = "1.1.1.1"
        #expect(form.shouldReload(for: VMSettings.Read(), profile: "other"))
    }

    @Test func aFormWhoseEditsAreInTheFileNowReloadsAndIsClean() {
        let form = loaded()
        form.dnsText = "1.1.1.1"
        form.addMount("/Volumes/Data")
        var read = VMSettings.Read()
        read.dnsServers = ["1.1.1.1"]
        read.mounts = [VMMount(location: "/Volumes/Data")]
        #expect(form.shouldReload(for: read, profile: "work"))
        form.load(read, sha: "bb", profile: "work")
        #expect(!form.isDirty && form.baselineSHA == "bb")
    }

    @Test func theFormKeepsTheShaOfTheFileThatItShows() {
        #expect(loaded().baselineSHA == "aa")
    }

    @Test func applyNeedsAnEditNoProblemAFreeProfileNoDebugRunAndAFile() {
        func can(
            dirty: Bool = true, problems: [String] = [], busy: Bool = false, debug: Bool = false, file: Bool = true
        ) -> Bool {
            VMConfigForm.canApply(isDirty: dirty, problems: problems, busy: busy, isDebug: debug, hasFile: file)
        }
        #expect(can())
        #expect(!can(dirty: false))
        #expect(!can(problems: ["x"]))
        #expect(!can(busy: true))
        #expect(!can(debug: true))
        #expect(!can(file: false))
    }
}
