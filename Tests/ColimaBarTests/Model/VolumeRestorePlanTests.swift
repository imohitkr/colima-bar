import Testing

@testable import ColimaBar

@Suite struct VolumeRestorePlanTests {
    @Test func aNewNameCreatesTheVolume() {
        #expect(VolumeRestorePlan.decide(exists: false, isEmpty: true, users: []) == .createNew)
    }

    @Test func anEmptyVolumeIsUsedAsItIs() {
        #expect(VolumeRestorePlan.decide(exists: true, isEmpty: true, users: []) == .useEmpty)
    }

    @Test func aVolumeWithFilesNeedsAConfirmedReplace() {
        #expect(VolumeRestorePlan.decide(exists: true, isEmpty: false, users: []) == .confirmReplace)
    }

    @Test func aVolumeWithFilesThatContainersUseIsRefused() {
        let plan = VolumeRestorePlan.decide(exists: true, isEmpty: false, users: ["db", "web"])
        #expect(plan == .refuse(users: ["db", "web"]))
    }
}
