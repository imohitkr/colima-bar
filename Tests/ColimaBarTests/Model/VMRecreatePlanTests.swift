import Foundation
import Testing

@testable import ColimaBar

@Suite struct VMRecreatePlanTests {
    private func image(_ id: String, _ repo: String, _ tag: String = "latest", size: Double = 100, used: Int = 1)
        -> ImageRow
    {
        ImageRow(id: id, repo: repo, tag: tag, size: size, created: Date(timeIntervalSince1970: 0), containers: used)
    }

    private func volume(_ name: String, size: Double = 10, anonymous: Bool = false) -> VolumeRow {
        VolumeRow(name: name, size: size, links: 0, project: nil, isAnonymous: anonymous)
    }

    private func inputs(
        running: Bool = true, socket: Bool = true, kept: Bool = true, kubernetes: Bool = false, rosetta: Bool = false,
        target: (String, String) = ("qemu", "sshfs"), volumes: [VolumeRow] = [], images: [ImageRow] = []
    ) -> VMRecreatePlan.Inputs {
        var read = VMSettings.Read()
        read.kubernetes = kubernetes
        read.rosetta = rosetta
        return .init(
            profile: "work", current: read, target: target, running: running, hasDockerSocket: socket,
            dataDiskKept: kept, volumes: volumes, images: images)
    }

    // MARK: Images and sizes

    @Test func theImagesInUseAreSavedByReferenceOrByIdWhenTheyHaveNoTag() {
        let plan = VMRecreatePlan.make(
            inputs(images: [
                image("sha256:a", "nginx", "1.27"),
                image("sha256:b", "<none>", "<none>"),
                image("sha256:c", "redis", used: 0),
                image("sha256:a", "nginx", "stable"),
                image("sha256:d", HelperImage.tag.split(separator: ":")[0].description, "1"),
            ]))
        #expect(plan.imageRefs == ["nginx:1.27", "sha256:b", "nginx:stable"])
    }

    @Test func theImageSizeCountsEachImageIdOnce() {
        let plan = VMRecreatePlan.make(
            inputs(images: [
                image("sha256:a", "nginx", "1", size: 100), image("sha256:a", "nginx", "2", size: 100),
                image("sha256:b", "redis", size: 50),
            ]))
        #expect(plan.imageBytes == 150)
    }

    @Test func theVolumeListHasTheNamedVolumesSortedAndTheirSize() {
        let plan = VMRecreatePlan.make(
            inputs(volumes: [volume("b", size: 5), volume("a", size: 7), volume("anon", size: 99, anonymous: true)]))
        #expect(plan.volumes.map(\.name) == ["a", "b"])
        #expect(plan.volumeBytes == 12)
    }

    @Test func theFolderNeedsTheChosenPartsPlusTenPercentAndTwoGiB() {
        let gib = Double(ByteFormat.bytesPerGiB)
        let plan = VMRecreatePlan.make(
            inputs(volumes: [volume("a", size: gib)], images: [image("sha256:a", "nginx", size: 2 * gib)]))
        let two = 2 * ByteFormat.bytesPerGiB
        #expect(plan.neededBytes(backUp: false, saveImages: false) == 0)
        #expect(plan.neededBytes(backUp: true, saveImages: false) == Int64(gib * 1.1) + two)
        #expect(plan.neededBytes(backUp: false, saveImages: true) == Int64(2 * gib * 1.1) + two)
        #expect(plan.neededBytes(backUp: true, saveImages: true) == Int64(3 * gib * 1.1) + two)
    }

    // MARK: Defaults

    @Test func theDefaultsFollowTheStateOfTheVMAndTheDataDisk() {
        let rows = [volume("a")]
        let images = [image("sha256:a", "nginx")]
        // running, kept: back up volumes, no images
        var plan = VMRecreatePlan.make(inputs(kept: true, volumes: rows, images: images))
        #expect(plan.canBackUp && plan.backUpByDefault && !plan.saveImagesByDefault)
        // running, no data disk: both
        plan = VMRecreatePlan.make(inputs(kept: false, volumes: rows, images: images))
        #expect(plan.backUpByDefault && plan.saveImagesByDefault)
        // stopped, or no docker socket: no backup
        for (running, socket) in [(false, true), (true, false)] {
            plan = VMRecreatePlan.make(
                inputs(running: running, socket: socket, kept: false, volumes: rows, images: images))
            #expect(!plan.canBackUp && !plan.backUpByDefault && !plan.saveImagesByDefault)
        }
        // nothing to back up
        plan = VMRecreatePlan.make(inputs(kept: false))
        #expect(plan.canBackUp && !plan.backUpByDefault && !plan.saveImagesByDefault)
    }

    // MARK: Data disk

    @Test func theDataDiskIsKeptOnlyWithItsFolderAndAFormattedStore() {
        func kept(folder: Bool, store: String?, profile: String = "work") -> Bool {
            VMRecreatePlan.dataDiskKept(
                profile: profile, colimaDir: "/c", limaDir: "/l",
                fileExists: { folder && $0 == "/l/_disks/\(Paths.limaInstance(profile))" },
                read: { $0 == "/c/_store/\(Paths.limaInstance(profile)).json" ? store : nil })
        }
        #expect(kept(folder: true, store: #"{"disk_formatted": true}"#))
        #expect(kept(folder: true, store: "{\n  \"disk_formatted\" :  true\n}"))
        #expect(kept(folder: true, store: #"{"disk_formatted":true}"#, profile: "default"))
        #expect(!kept(folder: false, store: #"{"disk_formatted":true}"#))
        #expect(!kept(folder: true, store: #"{"disk_formatted":false}"#))
        #expect(!kept(folder: true, store: nil))
        #expect(!kept(folder: true, store: "{}"))
    }

    // MARK: Warning

    @Test func theWarningNamesTheTypesAndTheDataDiskThatStays() {
        let i = inputs(kept: true)
        let text = VMRecreatePlan.warning(i, plan: .make(i))
        #expect(text.contains("from vz to qemu and the mount type from virtiofs to sshfs."))
        #expect(text.contains("Colima keeps the Docker data disk. Images, containers and volumes should stay."))
        #expect(text.contains("The VM restarts. Running containers stop."))
        #expect(text.contains("ColimaBar does not create containers again."))
        #expect(text.hasSuffix("\n\nTo continue, type the profile name: work"))
        #expect(!text.contains("deleted for good"))
    }

    @Test func theWarningSaysThatDataIsLostWithoutADataDisk() {
        let i = inputs(kept: false, kubernetes: true)
        let text = VMRecreatePlan.warning(i, plan: .make(i))
        #expect(text.contains("This VM has no separate Docker data disk."))
        #expect(text.contains("deleted for good. The Kubernetes cluster and its data are also deleted."))
        #expect(!text.contains("Kubernetes starts again"))
    }

    @Test func kubernetesStartsAgainWithADataDisk() {
        let i = inputs(kept: true, kubernetes: true)
        #expect(
            VMRecreatePlan.warning(i, plan: .make(i)).contains(
                "Kubernetes starts again. Its data stays on the data disk."))
    }

    @Test func rosettaTurnsOffOnlyForQEMU() {
        var i = inputs(rosetta: true, target: ("qemu", "sshfs"))
        #expect(VMRecreatePlan.warning(i, plan: .make(i)).contains("Rosetta turns off. It needs the vz VM type."))
        i = inputs(rosetta: true, target: ("vz", "sshfs"))
        #expect(!VMRecreatePlan.warning(i, plan: .make(i)).contains("Rosetta"))
        i = inputs(rosetta: false, target: ("qemu", "sshfs"))
        #expect(!VMRecreatePlan.warning(i, plan: .make(i)).contains("Rosetta"))
    }

    @Test func aStoppedVMStartsOnceAndCannotBeBackedUp() {
        var i = inputs(running: false, kept: true)
        var text = VMRecreatePlan.warning(i, plan: .make(i))
        #expect(text.contains("Colima starts the VM once to create it, then stops it again."))
        #expect(text.contains("ColimaBar can back up only while a docker VM runs."))
        #expect(!text.contains("Start the VM first to keep your data."))
        i = inputs(running: false, kept: false)
        text = VMRecreatePlan.warning(i, plan: .make(i))
        #expect(
            text.contains("ColimaBar can back up only while a docker VM runs. Start the VM first to keep your data."))
    }

    @Test func theWarningStartsFromTheDefaultsOfAFileWithNoTypes() {
        var i = inputs()
        i.current.vmType = "qemu"
        #expect(
            VMRecreatePlan.warning(i, plan: .make(i)).contains(
                "from qemu to qemu and the mount type from sshfs to sshfs."))
    }

    // MARK: Answer

    @Test func onlyTheTypedNameAndTheFirstButtonRecreate() {
        #expect(VMRecreatePlan.confirms(typed: " work ", profile: "work"))
        #expect(!VMRecreatePlan.confirms(typed: "Work", profile: "work"))
        #expect(!VMRecreatePlan.confirms(typed: "", profile: ""))
        #expect(
            VMRecreatePlan.answer(clicked: 0, typedOK: true, backUp: true, saveImages: false)
                == .recreate(backUp: true, saveImages: false))
        #expect(VMRecreatePlan.answer(clicked: 0, typedOK: false, backUp: true, saveImages: true) == .cancel)
        #expect(VMRecreatePlan.answer(clicked: 1, typedOK: true, backUp: true, saveImages: true) == .cancel)
    }
}
