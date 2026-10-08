import Foundation
import Testing

@testable import ColimaBar

@Suite @MainActor struct VMSettingsSectionTests {
    private let cpu = VMSettingsSection.cpuOpts
    private let mem = VMSettingsSection.memOpts

    @Test func keepsTheVMValueAfterAnotherIsPicked() {
        // Colima's default VM has 2 GB. After you pick 8 GB, 2 GB stays.
        #expect(VMSettingsSection.options(mem, 2, 8) == [2, 4, 8, 12, 16, 24, 32])
        #expect(VMSettingsSection.options(mem, 2, 2) == [2, 4, 8, 12, 16, 24, 32])
    }

    @Test func showsBothOffListValues() {
        #expect(VMSettingsSection.options(cpu, 3, 5) == [2, 3, 4, 5, 6, 8, 10, 12])
        #expect(VMSettingsSection.options(mem, 48, 2) == [2, 4, 8, 12, 16, 24, 32, 48])
    }

    @Test func aDecimalMemoryIsAnExtraOption() {
        // colima.yaml has `memory: 2.5`. The picker shows it, so it has a selection.
        #expect(VMSettingsSection.options(mem, 2.5, 2.5) == [2.5, 4, 8, 12, 16, 24, 32])
        #expect(VMSettingsSection.options(mem, 0.5, 8) == [0.5, 4, 8, 12, 16, 24, 32])
        #expect(VMSettingsSection.options(mem, 8, 8) == mem)
    }

    @Test func onlyTheProfileCPUOrMemoryResetsThePicks() {
        let shown = VMConfig.Shown(cpus: 4, memGB: 2.5, diskGB: 100)
        let key = VMSettingsSection.pickerKey(profile: "work", shown: shown)
        // Another profile with equal values resets an unsaved pick.
        #expect(VMSettingsSection.pickerKey(profile: "other", shown: shown) != key)
        var cpu = shown
        cpu.cpus = 8
        #expect(VMSettingsSection.pickerKey(profile: "work", shown: cpu) != key)
        var mem = shown
        mem.memGB = 3
        #expect(VMSettingsSection.pickerKey(profile: "work", shown: mem) != key)
        // A saved feature or disk keeps the pick.
        var other = shown
        other.diskGB = 200
        other.rosetta = true
        other.kubernetes = true
        other.rosettaSupported = false
        #expect(VMSettingsSection.pickerKey(profile: "work", shown: other) == key)
    }

    @Test func listedOrUnknownValuesAddNothing() {
        #expect(VMSettingsSection.options(cpu, 4, 8) == cpu)
        #expect(VMSettingsSection.options(cpu, 0, 0) == cpu)  // VM facts not loaded yet
        #expect(VMSettingsSection.options(mem) == mem)
    }
}
